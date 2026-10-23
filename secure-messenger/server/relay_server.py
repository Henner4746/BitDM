"""
relay_server.py  --  Relay- + Key-Server fuer BitDM
====================================================

Der Server ist BEWUSST dumm und kann Nachrichten NICHT lesen. Er macht nur:

  1. Prekey-Bundles speichern & ausliefern (fuer Signals X3DH-Sitzungsaufbau,
     damit man auch jemanden anschreiben kann, der gerade offline ist).
  2. Verschluesselte Umschlaege zwischen Nutzern weiterleiten (WebSocket) und
     zwischenspeichern, wenn der Empfaenger offline ist.

Alles echte Krypto (X3DH, Double Ratchet, Ver-/Entschluesselung) passiert in der
App. Der Server sieht nur base64-Blobs.

WAS SICH GEGENUEBER DEM ENTWURF GEAENDERT HAT
---------------------------------------------
S1  Auth laeuft jetzt ueber XEdDSA statt Ed25519. libsignal-Identitaetsschluessel
    sind Curve25519; mit `cryptography` allein waere die Pruefung unmoeglich
    gewesen und die Auth waere gebrochen, sobald der echte Client kommt.
S2  /register verlangt einen Besitznachweis. Vorher wurde nur geprueft, ob
    encode_id(identity_key) == user_id — das ist selbstreferenziell, jeder mit
    Kenntnis einer oeffentlichen Adresse konnte fremde Bundles ueberschreiben.
S3  /prekey ist ratenbegrenzt. Vorher konnte eine Schleife den One-Time-Prekey-
    Pool jedes Nutzers leeren.
S4  Offline-Warteschlange ist nach Anzahl, Groesse und Alter begrenzt.
S5  Persistenz in SQLite statt RAM; Fehlerbehandlung ist nicht mehr pauschal.
S6  MEHRGERAETE (30.07.2026, docs/MEHRGERAETE.md). Alles, was frueher an einer
    ADRESSE hing, haengt jetzt an (Adresse, Geraet): Buendel, Einmalschluessel,
    Warteschlange, WebSocket, Anstoss-Endpunkt. Grund ist keine Bequemlichkeit,
    sondern die Signal-Sitzung: sie ist eine Hashkette, und rasten zwei Geraete
    dieselbe Kette weiter, ist eine der beiden Nachrichten unwiederbringlich
    verloren. Deshalb eine Sitzung je GERAETEPAAR und ein Umschlag je Geraet.
    JEDE Geraeteangabe ist optional und bedeutet weggelassen "Geraet 1" — ein
    Client, der nichts davon weiss, merkt keinen Unterschied. Was beim
    Aufspielen mit einer bestehenden Datenbank passiert, steht bei
    wandere_auf_geraete().
S7  AUDIT vom 25.09.2026. Speicherdach und Aufraeumen fuer Nonces und Eimer,
    Deckel je Absender statt "die aelteste Zeile faellt" (schaffe_platz),
    mehrere offene Nonces je Geraet, Laengenpruefung im Buendel, IPv6 je /64
    und keine IP-Bremse ueber Tor, gedeckelter Vorraum fuer WebSockets,
    Rahmenbudget je Verbindung, strenges base64, kaputte Rahmen ohne
    Traceback, Marken nur noch je Stueck (33 MiB) plus Tagesmenge des ganzen
    Relays, Tarnverkehr bekommt ein ack. Das Protokoll fuer die Apps 1.6 bis
    1.8 ist unveraendert; neu sind nur Antworten, die sie schon kennen.
S8  KYBER-PREKEYS (16.10.2026, docs/LIBSIGNAL-UMSTIEG.md, MEHRGERAETE.md §15).
    Die App steigt auf Signals offizielle libsignal um, und die verlangt in
    JEDEM Prekey-Buendel einen signierten Kyber-Prekey (PQXDH). Der Relay
    speichert je Geraet einen Last-Resort-Kyber-Schluessel und einen Vorrat an
    Kyber-Einmalschluesseln und gibt sie bei /prekey aus. Alle Felder sind
    optional, bis der Betreiber BITDM_KYBER_PFLICHT=1 setzt — eine Anmeldung
    ohne Kyber sieht Byte fuer Byte aus wie vorher. Was es auf der Platte
    kostet und warum es dafuer ein eigenes Dach gibt, steht bei
    KYBER_OTK_MAX_GESAMT.

Ausserdem: Adressformat auf 56 Zeichen umgestellt (3-Byte-Pruefsumme statt 2),
damit Base32 glatt aufgeht und kein Padding abgeschnitten werden muss.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import ipaddress
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import urllib.parse
from typing import NamedTuple

import httpx
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from pydantic import BaseModel, Field
from xeddsa.bindings import curve25519_pub_to_ed25519_pub, ed25519_verify

# --------------------------------------------------------------------------- #
#  Konfiguration  (alles per Umgebungsvariable ueberschreibbar)
# --------------------------------------------------------------------------- #

DB_PATH = Path(os.getenv("BITDM_DB", "bitdm_relay.db"))

# Aufbewahrung. Umschalten auf "Wegwerf-Server" = diese Werte kleiner setzen;
# der Umbau ist damit eine Konfigurationsaenderung, kein Code-Eingriff.
QUEUE_TTL_SECONDS = int(os.getenv("BITDM_QUEUE_TTL", 14 * 24 * 3600))   # 14 Tage
QUEUE_MAX_PER_USER = int(os.getenv("BITDM_QUEUE_MAX", 500))             # Nachrichten
MAX_CIPHERTEXT_BYTES = int(os.getenv("BITDM_MAX_CT", 64 * 1024))        # 64 KiB

# Ein Challenge-Nonce ist kurzlebig und nur einmal verwendbar.
NONCE_TTL_SECONDS = 120

# Wie viele offene Nonces EIN (Adresse, Geraet)-Paar gleichzeitig haben darf.
#
# Frueher war es genau eines, und ein neues /register/challenge ueberschrieb
# das alte. Das war ein Hebel gegen FREMDE: die Adresse ist oeffentlich, also
# konnte jeder zwischen Challenge und /register des Opfers selbst eine
# Challenge fuer dieselbe Adresse holen — das Nonce des Opfers war weg, seine
# Registrierung scheiterte mit 401. Mit acht Plaetzen muss ein Stoerer acht
# Challenges in genau das Fenster zwischen den beiden Anfragen des Opfers
# legen (meist unter einer Sekunde), und zwar bei jedem Versuch neu.
NONCE_PLAETZE = int(os.getenv("BITDM_NONCE_SLOTS", 8))

# SEIT 14.10.2026 GEHOEREN DIE PLAETZE EINER HERKUNFT, nicht dem Paar.
#
# Mit acht Plaetzen je Paar blieb ein Rest (Pruefung vom 14.10.2026, B3): wer
# acht Challenges in das Fenster zwischen Challenge und /register des Opfers
# legte, verdraengte dessen Nonce weiterhin — ueber Tor ganz ohne Bremse, weil
# dort alle von 127.0.0.1 kommen. Jetzt hat jede Herkunft (IP, IPv6-/64,
# Tor-Circuit, siehe nonce_herkunft) ihre eigenen acht Plaetze. Ein Stoerer
# verdraengt damit nur seine eigenen Nonces; das des Opfers liegt in einer
# anderen Liste.
#
# Damit das Paar trotzdem nicht unbegrenzt waechst, gibt es ein Dach ueber
# alle Herkuenfte: NONCE_HERKUENFTE * NONCE_PLAETZE Eintraege. Erst darueber
# faellt das AELTESTE des Paares, gleich von wem. Einen Fremden kostet das
# also nicht acht Anfragen, sondern so viele aus mindestens NONCE_HERKUENFTE
# verschiedenen Netzen (oder Circuits), und zwar bei jedem Versuch neu. Das
# Dach haelt ausserdem die Zahl der Signaturpruefungen in /register klein
# (hoechstens 128 statt beliebig vieler).
NONCE_HERKUENFTE = int(os.getenv("BITDM_NONCE_ORIGINS", 16))

# ── Speicherdeckel fuer die beiden Tabellen im Arbeitsspeicher ────────────
#
# _nonces und _buckets wuchsen frueher unbegrenzt: /register/challenge nimmt
# JEDE gueltige Adresse an (die Pruefsumme rechnet sich jeder selbst), und
# jede Anfrage legte einen Nonce-Eintrag und einen Eimer an, die nie wieder
# verschwanden. Gemessen am 25.09.2026 (tracemalloc, 50 000 Anfragen): rund
# 600 Byte je Paar aus Nonce und Eimer — bei MemoryMax=512M keine Million
# Anfragen bis zum OOM-Kill, und der erschlaegt alle Verbindungen mit.
#
# Deshalb zweierlei: regelmaessig aufraeumen (abgelaufene Nonces, wieder volle
# Eimer — ein voller Eimer ist von einem fehlenden nicht zu unterscheiden) und
# ein festes Dach. Am Dach antwortet /register/challenge mit 503: das ist
# keine Bremse gegen EINEN, sondern ein Relay unter Last, und so soll es der
# Client auch verstehen.
#
# 200 000 Eintraege je Tabelle sind nach derselben Messung im schlechtesten
# Fall rund 120 MB zusammen — unter MemoryMax, weit ueber jedem ehrlichen
# Betrieb.
SPEICHER_MAX = int(os.getenv("BITDM_MEM_ENTRIES_MAX", 200_000))
# Spaetestens so oft wird aufgeraeumt (Sekunden) ...
AUFRAEUM_TAKT = 60.0
# ... und zusaetzlich, sobald eine Tabelle so gross wird — aber hoechstens
# einmal je Sekunde, sonst wuerde das Aufraeumen unter einer Flut selbst zur
# Last (jeder Lauf geht ueber die ganze Tabelle).
AUFRAEUM_AB = int(os.getenv("BITDM_MEM_PRUNE_AT", 50_000))

# Ratenbegrenzung, zweistufig.
#
# Je IP: nur ein grobes Missbrauchsnetz, bewusst grosszuegig. Ein scharfes
# IP-Limit waere hier sogar schaedlich — Mobilfunkanbieter setzen
# Carrier-Grade-NAT ein, hinter einer einzigen IP haengen tausende Kunden.
RATE_CAPACITY = int(os.getenv("BITDM_RATE_BURST", 120))
RATE_REFILL_PER_SEC = float(os.getenv("BITDM_RATE_REFILL", 2.0))

# Je Ziel-Adresse: das ist die eigentliche Verteidigung gegen den Prekey-Drain.
# Der Angriff zielt auf den Pool EINES Nutzers, also wird dort begrenzt — das
# wirkt unabhaengig davon, von wie vielen IPs der Angreifer kommt.
OTK_CAPACITY = int(os.getenv("BITDM_OTK_BURST", 10))
OTK_REFILL_PER_SEC = float(os.getenv("BITDM_OTK_REFILL", 0.1))   # 6 pro Minute

# Ab wann der Client aufgefordert wird, One-Time-Prekeys nachzuliefern.
OTK_LOW_WATERMARK = int(os.getenv("BITDM_OTK_LOW", 20))

# Je Absender: wie schnell EINER die Warteschlange fuellen darf.
#
# Greift wie otk_limit_ok je Adresse und nicht je IP. Die Adresse ist an dieser
# Stelle nachgewiesen (Challenge-Response beim Verbinden), die IP dagegen sagt
# nichts: hinter einer Mobilfunk-IP haengen tausende Kunden, siehe die
# Begruendung weiter oben.
#
# SEIT MEHRGERAETE VERDREIFACHT (60 -> 180, 2,0 -> 6,0/s). Der Eimer zaehlt
# RAHMEN, und mit Fanout kostet EINE Nutzernachricht n Rahmen — einer je Geraet
# der Gegenstelle plus einer je eigenem Zweitgeraet. Bei den alten 60 haette ein
# Absender mit drei Geraeten je Adresse nach 20 Nutzernachrichten "zu viele
# Nachrichten" bekommen, obwohl sich an seinem Verhalten nichts geaendert hat.
#
# Was das Dach kostet: 180 Rahmen x 64 KiB = 11,25 MiB Stoss je Absender
# (`py -c "print(180*65536/1024**2)"` -> 11.25). Bei drei Geraeten je Adresse
# bleiben das die frueheren 60 Nutzernachrichten, im schlechtesten Fall aus
# MEHRGERAETE.md §6 (9 Rahmen) noch 20. Die Platte bleibt trotzdem durch
# QUEUE_MAX_TOTAL und QUEUE_MAX_PER_USER gedeckelt — diese Bremse ist nicht die
# einzige Verteidigung, sondern nur die schnellste.
MSG_CAPACITY = int(os.getenv("BITDM_MSG_BURST", 180))
MSG_REFILL_PER_SEC = float(os.getenv("BITDM_MSG_REFILL", 6.0))

# Ein Dach ueber der GANZEN Tabelle. Der Deckel darunter (QUEUE_MAX_PER_USER)
# haengt an der Adresse, die der ABSENDER aussucht — ohne ein zweites, festes
# Dach ist er beliebig oft zu haben.
#
# 200 000 Zeilen sind im schlechtesten Fall (jede Zeile am
# MAX_CIPHERTEXT_BYTES-Limit) rund 12,2 GiB
# (`py -c "print(200000*65536/1024**3)"` -> 12.20703125; hier stand bis zum
# 30.07.2026 "12,5 GiB", das sind 2,4 % daneben). Dem stehen heute 31 Konten
# gegenueber, die zusammen hoechstens 15 500 Zeilen halten koennen — die Zahl
# trifft also keinen ehrlichen Betrieb, sondern nur die Flut. Sie gehoert an
# die Platte des jeweiligen Relays angepasst.
QUEUE_MAX_TOTAL = int(os.getenv("BITDM_QUEUE_MAX_TOTAL", 200_000))

# ── Deckel JE ABSENDER (Audit vom 25.09.2026) ─────────────────────────────
#
# QUEUE_MAX_PER_USER allein war eine Waffe: stand ein Geraet an seinem Deckel,
# fiel die aelteste Zeile weg — gleichgueltig, von wem sie war. Ein Fremder,
# der die Adresse kennt, konnte so mit 500 Rahmen alles wegspuelen, was
# echte Kontakte dem abwesenden Opfer hinterlassen hatten. Und QUEUE_MAX_TOTAL
# liess sich von EINEM Absender allein fuellen, der damit die Offline-
# Zustellung fuer alle anderen abstellte.
#
# QUEUE_MAX_JE_PAAR: so viele Zeilen darf EIN Absender bei EINEM Zielgeraet
# liegen haben. Darueber faellt SEINE eigene aelteste Zeile weg, nie die
# eines anderen. 100 ungelesene Nachrichten von einer Person an ein Geraet
# sind viel; wer mehr schreibt, verdraengt nur sich selbst.
#
# QUEUE_MAX_JE_ABSENDER: so viele Zeilen darf ein Absender insgesamt liegen
# haben, ueber alle Empfaenger. Darueber wird er abgewiesen ("Warteschlange
# voll", derselbe Wortlaut, den aeltere Clients schon kennen). 2000 sind 20
# volle Paare — weit ueber jedem ehrlichen Gebrauch, und 100 solcher
# Absender braucht es, um QUEUE_MAX_TOTAL zu fuellen statt einen.
QUEUE_MAX_JE_PAAR = int(os.getenv("BITDM_QUEUE_MAX_PAIR", 100))
QUEUE_MAX_JE_ABSENDER = int(os.getenv("BITDM_QUEUE_MAX_SENDER", 2000))

# ── Die WebSocket vor und nach der Anmeldung ──────────────────────────────
#
# Vor der Anmeldung kostet eine Verbindung den Angreifer nichts ausser einer
# gueltigen Adresse (die ist oeffentlich). Frueher durfte sie 30 s lang
# offen stehen, ohne Obergrenze — ueber Tor, wo alle von 127.0.0.1 kommen,
# griff auch kein nginx-Limit je IP. Ein Client braucht fuer die Antwort auf
# die Challenge eine Signatur, also Millisekunden; 10 s decken auch eine
# zaehe Tor-Strecke.
WS_ANMELDEFRIST = float(os.getenv("BITDM_WS_AUTH_TIMEOUT", 10.0))

# DIE NEUESTE VEROEFFENTLICHTE APP-FASSUNG (seit 26.09.2026). Geht bei der
# Anmeldung im auth_result mit ("neueste"); die App zeigt daraufhin einen
# ruhigen Hinweis "kannst du installieren, musst du aber nicht". Ueber den
# Relay und nicht ueber eine Abfrage bei GitHub oder bitdm.net: die App ist
# ohnehin mit ihm verbunden, und kein weiterer Server erfaehrt, wer BitDM
# benutzt. Leer = nichts mitschicken. Nur Ziffern und Punkte, sonst leer —
# der Wert landet unveraendert in der Oberflaeche.
NEUESTE_FASSUNG = os.getenv("BITDM_NEUESTE_FASSUNG", "").strip()
if not re.fullmatch(r"\d{1,4}(\.\d{1,4}){1,3}", NEUESTE_FASSUNG):
    NEUESTE_FASSUNG = ""
# Wie viele Verbindungen gleichzeitig im Vorraum stehen duerfen. Darueber
# wird sofort geschlossen (1013 "try again later"); ein ehrlicher Client
# verbindet nach seiner Wartezeit neu.
WS_VORRAUM_MAX = int(os.getenv("BITDM_WS_PREAUTH_MAX", 1000))

# Rahmen-Budget JE VERBINDUNG, fuer JEDE Art von Rahmen — auch die, die an
# keiner anderen Bremse haengen (empfangen, geraeus, unbekannte Arten,
# kaputtes JSON). Grosszuegig: nach dem Verbinden bestaetigt ein Client
# seinen ganzen Rueckstand (bis QUEUE_MAX_PER_USER = 500 Rahmen am Stueck),
# und Fanout vervielfacht jede Nutzernachricht. Wer es trotzdem leert, wird
# mit 4429 getrennt und darf neu verbinden.
RAHMEN_BURST = float(os.getenv("BITDM_FRAME_BURST", 1000))
RAHMEN_REFILL_PER_SEC = float(os.getenv("BITDM_FRAME_REFILL", 50.0))

# Bremse fuer das LIVE-Durchreichen an eine Gegenstelle ohne Empfangsnachweis
# (alte App). Bewusst NICHT msg_limit_ok: das ist die Bremse fuer die Platte,
# und eine laufende Unterhaltung darf sie nicht treffen
# (test_bremse_trifft_das_puffern_und_nicht_die_unterhaltung). Ungebremst
# war dieser Weg aber ein Verstaerker — jeder Rahmen des Absenders ging
# unbesehen in die Leitung des Empfaengers. Der eigene Eimer ist deshalb
# weiter als msg_limit_ok und haengt ebenfalls am Absender.
LIVE_CAPACITY = int(os.getenv("BITDM_LIVE_BURST", 600))
LIVE_REFILL_PER_SEC = float(os.getenv("BITDM_LIVE_REFILL", 20.0))

# ── Der ZWEITE Weg auf die Platte ─────────────────────────────────────────
#
# QUEUE_MAX_TOTAL deckelt die Warteschlange. /register schrieb daneben voellig
# ungedeckelt in `identities` und `one_time_prekeys` — und schlimmer: seit die
# Warteschlange eine Existenzpruefung hat, MUSS ein Angreifer sich erst
# registrieren, um sie ueberhaupt fluten zu koennen. Der eine Riegel trieb ihn
# also genau auf das groessere Leck.
#
# Nachgestellt am 27.07.2026: eine einzige IP schob in 30 Sekunden 35
# Registrierungen zu je 837 KiB durch — 20,4 MiB Wachstum, hochgerechnet rund
# 57 GiB am Tag, ohne eine einzige Ablehnung. Und anders als die Warteschlange
# heilt das nicht von selbst: `purge_expired` ruehrt diese beiden Tabellen
# nicht an, der Platz bleibt bis zur Handarbeit belegt.
#
# ZWEI GRENZEN, weil eine allein nicht reicht:
#
# OTK_MAX_JE_BUENDEL trifft die Menge. Die App laedt 100 Einmalschluessel
# hoch; nginx laesst 256 KiB Rumpf durch, das sind rund 2900. 200 ist
# doppelt so viel wie noetig und ein Vierzehntel dessen, was heute
# durchgeht — aus 837 KiB je Registrierung werden rund 7 KiB.
#
# IDENTITAETEN_MAX trifft die Anzahl. Ohne sie bliebe die Flut moeglich, sie
# dauerte nur laenger. 50 000 Identitaeten sind mit dem Deckel darueber im
# schlechtesten Fall rund 350 MiB — bei heute 31 Konten trifft die Zahl
# keinen ehrlichen Betrieb. Sie gilt NUR fuer neue Adressen: wer schon
# registriert ist, kann sein Bundle immer erneuern, sonst waere ein volles
# Relay fuer seine eigenen Nutzer unbenutzbar.
#
# NACHGEMESSEN AM 16.10.2026: die "350 MiB" rechnen ein Geraet je Adresse und
# nur die nackten Schluesselbytes. Mit GERAETE_MAX und dem, was SQLite je
# Zeile wirklich belegt (192 Byte je EC-Einmalschluessel samt Index), sind es
# im schlechtesten Fall rund 8,9 GiB — die ganze Rechnung fuer einen vollen
# Relay steht bei KYBER_OTK_MAX_GESAMT.
OTK_MAX_JE_BUENDEL = int(os.getenv("BITDM_OTK_MAX", 200))
IDENTITAETEN_MAX = int(os.getenv("BITDM_IDENTITIES_MAX", 50_000))

# DAS DACH LIESS SICH VON EINEM AKTEUR FUELLEN UND HALTEN (Audit vom
# 16.10.2026, SV-3). Eine Registrierung kostete je Herkunft 5 von 120 Marken
# der allgemeinen Bremse, rund 34 500 am Tag; bei IPv6 war jedes /64 eine
# eigene Herkunft (ein Heimanschluss hat 256), ueber Tor ohne Circuit-Kennung
# gab es gar keine. Nach wenigen Minuten nahm der Relay niemanden mehr auf,
# und gehalten wurde das mit einer Erneuerung im Monat. Seit 23.10.2026 drei
# Riegel:
#
# 1. NEUE ADRESSEN haben einen eigenen, engen Eimer: NEUE_ADRESSEN_JE_TAG je
#    Herkunft und Tag, bei IPv6 je /48 - ein ganzer Anschluss, nicht ein /64.
#    Ueber den Onion-Dienst zusaetzlich ein GEMEINSAMER Eimer
#    (NEUE_ADRESSEN_ONION_JE_TAG): ein Circuit ist billig zu wechseln. Den
#    Preis kennt die Bremse oben schon (Carrier-Grade-NAT, deploy/README.md):
#    hinter einer IPv4 bzw. in einem /48 teilen sich mehrere Kunden den Eimer.
#    Er trifft deshalb NUR neue Adressen - wer schon da ist, erneuert sein
#    Buendel und legt Geraete an wie bisher -, und 100 am Tag sind fuer einen
#    Relay dieser Groesse viel. Eine Marke kostet nur eine Adresse, die
#    wirklich angelegt wird (seit 24.10.2026, siehe neue_adresse_ok): eine
#    scheiternde Registrierung leert den geteilten Eimer nicht.
# 2. EINE ADRESSE, DIE SICH NIE VERBUNDEN HAT (last_seen = 0), geht nach
#    NIE_VERBUNDEN_TTL statt nach GERAET_TTL. Eine App meldet sich direkt
#    nach dem Registrieren per /ws an; wer das zwei Tage lang nicht tut, war
#    keine. Kommt sie doch, bekommt sie 4401 und registriert sich neu.
# 3. AB DACH_WARNUNG_AB DES DACHS meldet der Relay es im Journal, hoechstens
#    einmal je Stunde - damit es nicht still voll wird.
NEUE_ADRESSEN_JE_TAG = int(os.getenv("BITDM_NEUE_ADRESSEN", 100))
NEUE_ADRESSEN_ONION_JE_TAG = int(os.getenv("BITDM_NEUE_ADRESSEN_ONION", 500))
NIE_VERBUNDEN_TTL = int(os.getenv("BITDM_NIE_VERBUNDEN_TTL", 48 * 3600))
DACH_WARNUNG_AB = 0.8


# --------------------------------------------------------------------------- #
#  Kyber-Prekeys  (PQXDH, seit 16.10.2026 — docs/LIBSIGNAL-UMSTIEG.md)
# --------------------------------------------------------------------------- #
#
# Die offizielle libsignal (0.105, Dart-Paket `libsignal` 8.0.0) baut eine
# Sitzung nur noch mit PQXDH auf: `PreKeyBundle` verlangt zwingend einen
# Kyber-Prekey mit Kennung und Signatur, ein Buendel ohne ist dort gar nicht
# baubar (Machbarkeitsversuch vom 16.10.2026, LIBSIGNAL-UMSTIEG.md). Der Relay
# sieht davon nur Bloecke, die er speichert und weiterreicht — er prueft
# Laenge, Typbyte und Signatur, mehr nicht. Ob der Block ein gueltiger
# ML-KEM-Schluessel ist, merkt erst der Absender beim Kapseln; ein kaputter
# Block schadet also nur dem, der ihn hochgeladen hat.
#
# Ein Kyber-1024-Schluessel ist 1568 Byte lang, libsignal setzt beim
# Serialisieren das Typbyte 0x08 davor, genau wie 0x05 vor einen
# Curve25519-Schluessel. Signiert werden die vollen 1569 Byte MIT Typbyte
# (so legt libsignal den Kyber-Prekey an: die Signatur geht ueber
# `public_key.serialize()`), also genau so, wie der signierte EC-Prekey seine
# 33 Byte mit 0x05 signiert. Eine Signatur ueber die nackten 1568 Byte waere
# fuer den Absender wertlos — libsignal prueft beim Sitzungsaufbau gegen die
# serialisierte Form und wirft `invalidSignature`. Deshalb weist der Relay sie
# gleich ab, statt ein Buendel auszugeben, mit dem niemand etwas anfangen kann.
KYBER_SCHLUESSEL_LAENGE = 1569
KYBER_TYPBYTE = 0x08

# Kennungen der Kyber-Prekeys: 0 <= id <= 2^31-1, so ist es mit der App
# vereinbart. libsignal selbst nimmt u32; die halbe Spanne laesst jeder
# Sprache auf beiden Seiten ein vorzeichenbehaftetes int32 und haelt
# OverflowError beim Binden an SQLite fern (siehe register()).
KYBER_KENNUNG_MAX = 2**31 - 1

# Wie viele Kyber-EINMALschluessel ein Buendel tragen darf.
#
# 50 und nicht OTK_MAX_JE_BUENDEL (200), aus drei Gruenden, alle gemessen am
# 16.10.2026:
#
# RUMPF. Ein Einmalschluessel ist im JSON 2233 Byte lang (2092 Zeichen
# base64 fuer 1569 Byte, 88 fuer die Signatur, dazu Kennung und Klammern).
# Ein Buendel mit 200 EC- und 50 Kyber-Einmalschluesseln, alle Kennungen am
# oberen Rand, ist 130 849 Byte = 127,8 KiB — die Haelfte dessen, was nginx
# durchlaesst (client_max_body_size 256k, install-relay.sh und
# onion/relay-onion.nginx). Mehr als rund 108 gingen dort gar nicht mehr
# durch; 200 hiesse, dass nginx und nicht dieser Deckel die Grenze zieht.
#
# PLATTE. 2141 Byte je Zeile samt Primaerschluessel-Index (bei 4-KiB-Seiten
# passen nur zwei Zeilen auf eine Seite), also rund 105 KiB je Geraet. Ein
# EC-Einmalschluessel kostet 192 Byte; 50 Kyber-Schluessel sind damit fast
# dreimal so viel wie 200 EC-Schluessel.
#
# CPU. Jede Signatur wird geprueft, 98 Mikrosekunden je Stueck: 51 Pruefungen
# (50 + Last-Resort) sind 5,0 ms je Anmeldung — in derselben Groessenordnung
# wie der Besitznachweis im schlechtesten Fall (128 offene Nonces x 90 us =
# 11,5 ms). Bei 200 waeren es 20 ms, gerechnet im Threadpool, aber unter der
# Ratenbremse "reg" fuer jeden, der eine eigene Identitaet hat.
#
# Was die App braucht: sie fuellt nach, wenn der Vorrat unter
# OTK_LOW_WATERMARK (20) faellt. Mit 50 bleiben 30 neue Kontakte zwischen
# zwei Nachlieferungen — fuer einen Messenger zwischen Bekannten reichlich.
KYBER_OTK_MAX_JE_BUENDEL = int(os.getenv("BITDM_KYBER_OTK_MAX", 50))

# EIN DACH UEBER DIE GANZE TABELLE one_time_kyber_prekeys.
#
# WARUM ES DAS BRAUCHT — die Rechnung fuer einen vollen Relay, gemessen mit
# SQLite 3.50.4 und 4-KiB-Seiten (Messskript: Zeilen einfuegen, page_count x
# page_size vorher und nachher):
#
#   identities, je Geraet ohne Kyber            367 Byte
#   identities, je Geraet mit Last-Resort-Kyber 2126 Byte
#   one_time_prekeys, je Zeile                  192 Byte
#   one_time_kyber_prekeys, je Zeile           2141 Byte
#
# Ein voller Relay sind IDENTITAETEN_MAX x GERAETE_MAX = 50 000 x 5 =
# 250 000 Geraete. Das kostet im schlechtesten Fall
#
#   Warteschlange (QUEUE_MAX_TOTAL x 64 KiB)            12,2 GiB
#   EC-Einmalschluessel  250 000 x 200 x 192 Byte        8,9 GiB
#   identities mit Kyber 250 000 x 2126 Byte              0,5 GiB
#   Kyber-Einmal OHNE Dach 250 000 x 50 x 2141 Byte      24,9 GiB
#
# (`py -c "print(250000*50*2141/1024**3)"` -> 24.92...). Zusammen 46,6 GiB —
# mehr, als auf dem Haupt-VPS ueberhaupt frei ist (rund 36 GB). Die Kyber-
# Einmalschluessel allein waeren der groesste Posten, groesser als die ganze
# Warteschlange, und anders als die heilen sie nicht von selbst: purge_expired
# ruehrt sie nicht an. IDENTITAETEN_MAX haelt also die ANZAHL, aber nicht mehr
# den PLATZ — dafuer ist es nicht gebaut, eine Adresse kostet nichts als ein
# Schluesselpaar.
#
# MIT DACH: 500 000 Zeilen x 2141 Byte = 1,0 GiB
# (`py -c "print(500000*2141/1024**3)"` -> 0.997). Ein voller Relay braucht
# damit 12,2 + 8,9 + 0,5 + 1,0 = 22,6 GiB. Ehrlich passen darunter 10 000
# Geraete mit vollem Vorrat — bei heute 31 Konten trifft die Zahl nur die
# Flut. Wie QUEUE_MAX_TOTAL gehoert sie an die Platte des Relays angepasst.
#
# AM DACH WIRD NICHT ABGEWIESEN, sondern gekuerzt: eine Anmeldung geht durch,
# Last-Resort-Schluessel und EC-Teil werden gespeichert, vom Kyber-Vorrat nur
# so viel, wie noch Platz ist (register(), Antwortfeld
# one_time_kyber_prekeys). Ein Geraet ohne Kyber-Einmalschluessel ist
# weiterhin erreichbar — /prekey gibt dann den Last-Resort-Schluessel aus,
# PQXDH laeuft, nur ohne die Einmal-Eigenschaft. Das ist dieselbe Abwaegung
# wie beim geleerten EC-Vorrat: schwaecher, aber kein Ausfall. Eine Absage
# dagegen traefe genau die ehrlichen Nutzer, die nach einer Flut kommen, und
# liesse sie gar nicht mehr nachliefern — auch ihren signierten Prekey nicht.
KYBER_OTK_MAX_GESAMT = int(os.getenv("BITDM_KYBER_OTK_MAX_TOTAL", 500_000))


def kyber_pflicht() -> bool:
    """Ob /register eine Anmeldung OHNE Kyber-Prekey abweist (Stichtag).

    BEI JEDEM AUFRUF GELESEN und nicht einmal beim Import, aus demselben Grund
    wie blob_geheimnis(): der Schalter ist eine Betriebsentscheidung, kein
    Tuning-Wert, und der Test prueft so den ECHTEN Variablennamen — ein
    Tippfehler im Namen fiele bei einer Modulkonstante, die der Test von
    aussen setzt, nie auf. Kostet ein Nachschlagen im Umgebungsblock je
    Anmeldung.

    Nur genau "1" schaltet ein. "true", "ja" oder ein Leerzeichen zu viel
    lassen den Uebergang offen — eine Fehlbedienung soll im Zweifel alte Apps
    weiter anmelden, statt sie auszusperren.
    """
    return os.getenv("BITDM_KYBER_PFLICHT", "") == "1"


# --------------------------------------------------------------------------- #
#  Mehrgeraete  (MEHRGERAETE.md §6, §7)
# --------------------------------------------------------------------------- #
#
# Bei BitDM IST die Adresse der oeffentliche Schluessel, und der kommt
# deterministisch aus den zwoelf Woertern. Wer sie hat, ist die Adresse — es
# gibt kein Geraet mit mehr Recht darauf als ein anderes und deshalb auch kein
# Hauptgeraet, keine Kopplungsmaske und keinen Widerruf. Was es geben MUSS, ist
# eine eigene Signal-Sitzung je GERAETEPAAR: eine Sitzung ist eine Hashkette,
# und rasten zwei Geraete dieselbe Kette weiter, ist eine der beiden
# Nachrichten unwiederbringlich verloren (MEHRGERAETE.md §10).
#
# Wie viele Geraete EINE Adresse fuehren darf.
#
# Jedes Geraet kostet dem ABSENDER eine eigene Verschluesselung und diesem
# Server eine eigene Warteschlangenzeile. Schlechtester Fall fuer EINE
# Nutzernachricht: 5 Geraete der Gegenstelle + 4 eigene = 9 Umschlaege. Platte
# je Adresse: 5 x QUEUE_MAX_PER_USER 500 x MAX_CIPHERTEXT_BYTES 64 KiB =
# 156,25 MiB (`py -c "print(5*500*65536/1024**2)"` -> 156.25; je Geraet
# 31,25 MiB). Einmalschluessel: 5 x 100 = 500 je Adresse, OTK_MAX_JE_BUENDEL
# gilt weiter JE BUENDEL, also je Geraet.
#
# Fuenf deckt Telefon + Tablet + Laptop + Schreibtisch + Reserve.
GERAETE_MAX = int(os.getenv("BITDM_GERAETE_MAX", 5))

# Ab wann ein Geraet als vergessen gilt und samt seiner Warteschlange
# weggeraeumt wird.
#
# WARUM ES DIESE FRIST BRAUCHT: die Warteschlange haengt jetzt am Geraet. Ein
# totes Telefon steht dauerhaft an seinem Deckel (QUEUE_MAX_PER_USER), und ab
# da faellt fuer JEDEN Absender an dieses Geraet die aelteste Zeile weg —
# solange die Zeile lebt, ist die Adresse teilweise unbeschickbar. Bei einer
# Warteschlange je Adresse fiel das niemandem auf.
#
# 30 Tage sind laenger als der Urlaub eines Tablets und kuerzer als
# "vergessen". Entscheidet der Betreiber, wie alle Aufbewahrungsfristen.
GERAET_TTL = int(os.getenv("BITDM_GERAET_TTL", 30 * 24 * 3600))

# --------------------------------------------------------------------------- #
#  Geraeteliste  (docs/GERAETEABMELDUNG.md §8, seit 17.10.2026)
# --------------------------------------------------------------------------- #
#
# WARUM ES SIE GIBT: alle Geraete einer Adresse teilen den Identitaets-
# schluessel, er kommt aus den zwoelf Woertern. Ein Geraet nur hier zu
# loeschen hielt deshalb nicht einmal ein Telefon in der Schublade auf — die
# App meldete sich auf 4401 von selbst neu an. Jetzt fuehrt jede Adresse eine
# Liste ihrer Geraete, jedes mit einem EIGENEN, zufaelligen Geraeteschluessel.
# Nur wer darin steht und mit seinem Geraeteschluessel unterschreibt, kommt
# durch /register und /ws. Aendern darf die Liste ein Geraet, das schon darin
# steht; mit dem Identitaetsschluessel allein geht nur das ZURUECKSETZEN auf
# ein einziges Geraet — und das ist laut, jedes andere Geraet faellt dabei
# sichtbar heraus.
#
# Drei feste Praefixe trennen, wofuer eine Signatur gilt. Ohne sie waere eine
# Unterschrift unter einer Liste womoeglich auch eine unter einer Anmeldung.
LISTE_PRAEFIX = b"BitDM-Geraeteliste-v1\n"
BEITRITT_PRAEFIX = b"BitDM-Beitritt-v1\n"
ANMELDE_PRAEFIX = b"BitDM-Geraet-Anmeldung-v1\n"
# Der signierte Prekey, zusaetzlich vom Geraeteschluessel unterschrieben
# (GERAETEABMELDUNG.md §12.5 a). Ohne das liesse sich das Buendel eines
# abgemeldeten Geraets unter der Kennung eines gelisteten ausliefern — vom
# Identitaetsschluessel signiert ist es ja auch.
PREKEY_PRAEFIX = b"BitDM-Prekey-v1\n"

# --------------------------------------------------------------------------- #
#  Anmeldung mit Kontext  (Audit vom 16.10.2026, KR-2 / SV-9; seit 23.10.2026)
# --------------------------------------------------------------------------- #
#
# BIS 2.0.0 SIGNIERT DIE APP DAS NONCE DIESES SERVERS ROH: bei /ws `nonce`
# bzw. `nonce || uint32be(geraet)`, bei /register `nonce || sha256(buendel)`.
# Ohne Zweck und ohne Empfaenger. Ein boesartiger Relay A reicht dann die
# Challenge von Relay B an das Opfer weiter, bekommt die Signatur und meldet
# sich damit bei B als das Opfer an: Warteschlange abholen (und damit
# loeschen), Geraet mit 4409 verdraengen, ein eigenes Buendel registrieren.
# Mitlesen kann er nicht. Die zweite Haelfte des Befunds - das Signieren
# fremder Formate (33 Byte `0x05 || K`, 64 Byte Registrierung) - schliesst die
# App seit 2.0.0 selbst: ein Nonce hat genau 32 Byte (relay_client.dart,
# nonceLaenge).
#
# DIE NEUE FORM nennt Zweck, Relay, Adresse und Geraet:
#
#   /ws:       "BitDM-Relay-Anmeldung-v1\n"     host "\n" adresse "\n" geraet "\n" nonce
#   /register: "BitDM-Relay-Registrierung-v1\n" host "\n" nonce sha256(buendel)
#
# `host` ist der Name, unter dem die APP den Relay erreicht hat (ihre eigene
# Basis-URL, nicht ein Wert dieses Servers), und dieser Server nimmt nur die
# Namen an, die in BITDM_RELAY_NAMEN stehen. Eine Signatur fuer A gilt damit
# bei B nicht.
#
# BEIDE FORMEN WERDEN ANGENOMMEN. Die App 2.0.0 ist ausgeliefert und kennt nur
# die alte; sie darf hier nicht ausgesperrt werden. Welche Form kommt, sagt
# der Client selbst: mit dem Feld `relay` (der Name) die neue, ohne die alte.
# Erst BITDM_ANMELDUNG_PFLICHT=1 weist die alte ab - das ist der Schalter fuer
# den Tag, an dem keine App vor der neuen Form mehr unterwegs ist.
#
# Die Challenge nennt dazu die Namen, die dieser Relay annimmt (Feld `relay`
# in der Challenge bzw. in der Antwort auf /register/challenge). Eine App
# signiert die neue Form nur, wenn ihr eigener Name darin steht - so sperrt
# ein vergessener Name (etwa die Onion-Adresse) niemanden aus, er faellt auf
# die alte Form zurueck. Das ist kein Herunterhandeln, das ein Angreifer
# braucht: einem Relay, der die Liste weglaesst, gibt die App nur, was sie
# ihm heute schon gibt, und am Tag des Schalters nimmt B das nicht mehr an.
ANMELDUNG_WS_PRAEFIX = b"BitDM-Relay-Anmeldung-v1\n"
REGISTRIERUNG_PRAEFIX = b"BitDM-Relay-Registrierung-v1\n"

# Ein Hostname, eine IPv4- oder eine IPv6-Adresse (ohne Klammern, so liefert
# Dart Uri.host sie). Kein Zeilenumbruch, kein Port: der Relay hinter nginx
# kennt den Port nicht, unter dem man ihn erreicht.
#
# BIS ZUM 24.10.2026 war das EIN Zeichenmuster, [a-z0-9.:-]{1,253}. Der
# Doppelpunkt stand fuer IPv6 drin und liess so auch "relay.bitdm.net:443"
# durch. Die App nennt ihren Namen ohne Port (Uri.host), fand sich in der
# Liste nicht und fiel still auf die alte Form zurueck - mit
# BITDM_ANMELDUNG_PFLICHT=1 waere sie ausgesperrt worden, ohne dass der
# Betreiber je einen Hinweis bekommen haette. Jetzt gilt ein Doppelpunkt nur
# in einer echten IPv6-Adresse, und was nicht passt, meldet melde_relay_namen()
# beim Start.
RELAY_NAME_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")


def relay_name_ok(name: str) -> bool:
    """Ob `name` (schon klein geschrieben) als Relay-Name taugt: ein Hostname
    aus Labels nach RFC 1123, eine IPv4- oder eine IPv6-Adresse."""
    if not name or len(name) > 253:
        return False
    if ":" in name:
        # Nur IPv6. "%" (Zonenkennung) nimmt ipaddress an, Uri.host liefert
        # sie aber nicht - und "host:port" scheitert genau hier.
        if "%" in name:
            return False
        try:
            ipaddress.IPv6Address(name)
        except ValueError:
            return False
        return True
    labels = name.split(".")
    if not all(RELAY_NAME_LABEL.fullmatch(label) for label in labels):
        return False
    if all(label.isdigit() for label in labels):
        # Sieht aus wie eine IPv4-Adresse, dann muss es auch eine sein:
        # "10.0.0.300" ist ein Tippfehler, kein Hostname.
        try:
            ipaddress.IPv4Address(name)
        except ValueError:
            return False
    return True


def _lies_relay_namen() -> tuple[tuple[str, ...], tuple[str, ...]]:
    """BITDM_RELAY_NAMEN, aufgeteilt in (gueltig, abgelehnt). Leere Eintraege
    (etwa ein Komma am Ende) sind keins von beiden."""
    gueltig: list[str] = []
    abgelehnt: list[str] = []
    for eintrag in os.getenv("BITDM_RELAY_NAMEN", "").split(","):
        name = eintrag.strip().lower()
        if name:
            (gueltig if relay_name_ok(name) else abgelehnt).append(name)
    return tuple(gueltig), tuple(abgelehnt)


def relay_namen() -> tuple[str, ...]:
    """Die Namen, unter denen dieser Relay die neue Anmeldeform annimmt.

    BITDM_RELAY_NAMEN, durch Kommas getrennt, z. B.
    "relay.bitdm.net,<onion>.onion". Leer heisst: keine neue Form, nur die
    alte - und die Challenge nennt dann auch keine Namen. Ungueltige Eintraege
    (relay_name_ok) werden nie uebernommen; gemeldet werden sie einmal beim
    Start (melde_relay_namen), nicht bei jeder Anfrage.

    BEI JEDEM AUFRUF GELESEN, aus demselben Grund wie kyber_pflicht().
    """
    return _lies_relay_namen()[0]


def melde_relay_namen() -> None:
    """Beim Start einmal ins Journal: welche Namen gelten, und laut, welche
    Eintraege abgelehnt wurden.

    Abgelehnt heisst NICHT abgestuerzt: ein Tippfehler in einem Namen soll
    den Relay nicht fuer alle anderen Namen und fuer die alte Form vom Netz
    nehmen. Die Namen sind nicht geheim (die Challenge nennt sie jedem); ein
    abgelehnter Eintrag steht gekuerzt da, falls versehentlich etwas anderes
    in der Variable gelandet ist.
    """
    gueltig, abgelehnt = _lies_relay_namen()
    for eintrag in abgelehnt:
        kurz = eintrag if len(eintrag) <= 80 else eintrag[:80] + "..."
        print(f"[!] BITDM_RELAY_NAMEN: Eintrag {kurz!r} abgelehnt und NICHT "
              f"uebernommen - kein Hostname und keine IP-Adresse (einen Port "
              f"kennt die App hier nicht). Apps, die den Relay so erreichen, "
              f"melden sich in der alten Form an; mit "
              f"BITDM_ANMELDUNG_PFLICHT=1 gar nicht mehr.")
    if gueltig:
        print(f"[i] Relay-Namen fuer die Anmeldung mit Kontext: "
              f"{', '.join(gueltig)}")
    else:
        print("[i] Keine Relay-Namen (BITDM_RELAY_NAMEN): nur die alte "
              "Anmeldeform")


def anmeldung_pflicht() -> bool:
    """Ob die alte Anmeldeform (ohne Kontext) abgewiesen wird.

    Nur genau "1" schaltet ein, wie bei kyber_pflicht(): eine Fehlbedienung
    soll im Zweifel alte Apps weiter anmelden, statt sie auszusperren.
    """
    return os.getenv("BITDM_ANMELDUNG_PFLICHT", "") == "1"


def ws_anmelde_nachricht(host: str, user_id: str, geraet: int,
                         nonce: bytes) -> bytes:
    """Was die App bei /ws in der neuen Form signiert. Dieselben Bytes baut
    relay_client.dart (anmeldeNachricht)."""
    return (ANMELDUNG_WS_PRAEFIX
            + f"{host}\n{user_id}\n{geraet}\n".encode("ascii") + nonce)


def registrier_nachricht(host: str, nonce: bytes, inhalt: bytes) -> bytes:
    """Was die App bei /register in der neuen Form signiert. Adresse und
    Geraet stehen schon im Buendel (canonical_bytes), also im Hash."""
    return REGISTRIERUNG_PRAEFIX + f"{host}\n".encode("ascii") + nonce + inhalt


def angemeldeter_relay(feld: object) -> tuple[bool, str | None]:
    """Welche Form ein Client gewaehlt hat. Rueckgabe: (zulaessig, host).

    host None ist die alte Form - zulaessig, solange anmeldung_pflicht() aus
    ist. Ein Name, den dieser Relay nicht fuehrt, ist nie zulaessig: genau
    das ist die weitergereichte Challenge eines anderen Relays.
    """
    if feld is None:
        return not anmeldung_pflicht(), None
    if not isinstance(feld, str) or feld not in relay_namen():
        return False, None
    return True, feld

# Eine Liste mit 5 Geraeten ist rund 1,3 KB (je Eintrag 44 Zeichen Schluessel
# und hoechstens GERAETE_INFO_MAX Info). 4096 laesst Luft und haelt jeden
# Unsinn draussen, bevor json.loads ihn sieht.
LISTE_MAX_ZEICHEN = 4096
# Die verschluesselte Info je Geraet (Name, seit wann). Der Relay sieht davon
# nur Rauschen; die Grenze ist nur Platte.
GERAETE_INFO_MAX = 512
# Epoche und Zeit bleiben unter 2^53, damit sie in JavaScript (Web-App) noch
# genau sind.
EPOCHE_MAX = 2**53

# Wie lange eine Beitrittsanfrage wartet und wie viele je Adresse.
#
# Kurz und wenige, weil eine Anfrage nur einen Zweck hat: das Mitglied, das
# gerade daneben liegt, bestaetigt sie. Wer die Woerter hat und Anfragen
# flutet, verdraengt damit nur seine eigenen — und jede braucht ohnehin den
# Identitaetsschluessel.
BEITRITT_TTL = int(os.getenv("BITDM_BEITRITT_TTL", 600))
BEITRITTE_JE_ADRESSE = 3

# Schlusscode an ein Geraet, das nicht (mehr) in der Liste steht. NICHT 4401:
# darauf meldet sich die App neu an, und genau das soll ein abgemeldetes
# Geraet nicht tun.
WS_ABGEMELDET = 4410


# --------------------------------------------------------------------------- #
#  Das Zwischenlager  (dateien.bitdm.net, siehe blob_server.py)
# --------------------------------------------------------------------------- #
#
# Grosse Anhaenge gehen nicht durch diesen Server. Er stellt nur die Erlaubnis
# aus, sie woanders abzulegen — er weiss ja schon, wem eine Adresse gehoert,
# weil er es beim Verbinden geprueft hat. Das Lager muesste denselben Nachweis
# sonst ein zweites Mal fuehren.
#
# WAS DIESER SERVER DABEI NICHT SIEHT: den Inhalt (verschluesselt), den
# Schluessel (reist als gewoehnliche Nachricht) und die Datei selbst (liegt auf
# einem anderen Rechner). Er sieht: wer wann wie viele Bytes ablegen will —
# und die Kennung des Stuecks, im Klartext im Rahmen, weil er sie in die Marke
# rechnen muss. Er SPEICHERT sie nicht (siehe blob_marken), aber "blind" ist
# das nicht; hier stand bis zum 25.09.2026 das Gegenteil.

BLOB_BASIS = os.getenv("BITDM_BLOB_BASE", "https://dateien.bitdm.net")

# Groesstes STUECK, fuer das eine Marke ausgestellt wird. Muss zu MAX_BYTES in
# blob_server.py passen: eine Marke fuer mehr auszustellen, als das Lager
# annimmt, hiesse den Client erst laden zu lassen und ihn dann abzuweisen.
#
# SEIT 25.09.2026 33 MiB STATT 5 GiB. Eine Marke gilt fuer EIN Stueck, nicht
# fuer eine Datei: die App zerlegt jede Datei in Stuecke zu 32 MiB
# (anhang_versand.dart, standardStueckGroesse) und holt je Stueck eine Marke;
# hochgeladen wird das Stueck mit seinem 16-Byte-GCM-Anhang. Die 5 GiB waren
# die Obergrenze fuer die ganze DATEI (hoechstGroesse in der App) und hier
# falsch verortet — sie erlaubten einem einzelnen PUT, 5 GiB am Stueck zu
# schreiben. 33 MiB lassen ein MiB Luft ueber dem echten Stueck.
BLOB_MAX_BYTES = int(os.getenv("BITDM_BLOB_MAX", 33 * 1024**2))

# Wie lange eine Marke gilt. Grosszuegig, und das ist vertretbar: sie gilt fuer
# GENAU EINE Kennung und GENAU EINE Groesse, und eine schon belegte Kennung
# weist das Lager ab. Eine kurze Frist wuerde dagegen jeden Upload treffen, der
# ueber eine schlechte Mobilfunkstrecke laenger dauert — und das ist genau der
# Fall, fuer den das Lager gebaut ist.
BLOB_MARKE_TTL = int(os.getenv("BITDM_BLOB_MARKE_TTL", 12 * 3600))

# Wie viel eine Adresse pro Tag ablegen darf.
#
# DAS IST DIE EIGENTLICHE VERTEIDIGUNG, nicht die Marke. Die Marke haelt
# Fremde draussen — aber eine Adresse anzulegen kostet nichts als ein
# Schluesselpaar. Ohne diese Grenze koennte sich jemand ein paar Adressen
# machen und die Platte in einer Nacht fuellen.
# Seit dem 26.07.2026 auf 25 GiB: bei einer Obergrenze von 5 GiB je Datei
# (die gilt in der App weiter) waeren 10 GiB genau zwei Dateien am Tag, und
# die zweite haette schon scheitern koennen, weil eine verfallene Marke ihr
# Kontingent behaelt. 25 GiB sind rund 775 Stuecke zu 33 MiB.
BLOB_TAGESMENGE = int(os.getenv("BITDM_BLOB_QUOTA", 25 * 1024**3))

# DIE MENGE DES GANZEN RELAYS ZAEHLT SEIT 23.10.2026 DAS LAGER, nicht mehr
# dieser Server (blob_server.py, TAGESMENGE_GESAMT; Audit vom 16.10.2026,
# SV-2). Hier stand bis dahin BLOB_TAGESMENGE_GESAMT: 200 GiB an MARKEN je
# Tag, gezaehlt beim Ausstellen. Eine Marke kostet aber keinen Upload - neun
# kostenlose Adressen holten sich in Sekunden 200 GiB an Marken, luden nichts
# hoch, und danach bekam 24 Stunden lang JEDER "Zwischenlager fuer heute
# ausgelastet". Die Grenze sollte die Geschwindigkeit begrenzen, mit der sich
# die Platte fuellt; gefuellt werden musste dafuer nichts.
#
# Das Lager zaehlt die Bytes, die wirklich ankommen. Wer dort die Tagesmenge
# ausschoepfen will, muss sie hochladen - genau der Preis, den die Grenze
# setzen sollte. `BITDM_BLOB_QUOTA_TOTAL` gehoert deshalb in die Unit des
# Lagers; hier liest sie niemand mehr.
#
# Und die Summe ueber den ganzen Relay lief synchron im WebSocket-Handler,
# ueber bis zu 204 800 Zeilen: gemessen 498 ms je Marke, in denen keine
# andere Verbindung bedient wurde (SV-1). Mit ihr ist auch das weg.

# Wie fein `blob_marken` die Tagesmenge je Adresse festhaelt: EINE Zeile je
# Adresse und angefangener Stunde (seit 23.10.2026, SV-1).
#
# Vorher war es eine Zeile je Marke, bis zu 25 600 je Adresse und Tag. Die
# Summe je Adresse lief ueber alle davon - 76 ms je Marke auf dem Event-Loop,
# gemessen vom Audit. Jetzt sind es hoechstens 25 Zeilen (24 Stunden plus die
# angefangene), und die Tabelle waechst mit der Zahl der Adressen, nicht mit
# der Zahl der Marken. Nebenbei steht weniger darin: nicht mehr jede Marke
# mit ihrer Sekunde, nur noch die Summe je Stunde.
#
# DER PREIS DER STUNDE: eine Stunde zaehlt ganz mit, solange auch nur ihr
# Ende in den letzten 24 Stunden liegt. Eine Marke belastet die Tagesmenge
# damit bis zu 25 statt 24 Stunden - die strengere Richtung, wie beim
# Ausstellen.
BLOB_STUNDE = 3600
BLOB_FENSTER = 24 * 3600 + BLOB_STUNDE

# Was eine Marke MINDESTENS von der Tagesmenge kostet (seit 14.10.2026).
#
# Gezaehlt wurden nur Bytes. Eine Marke fuer 1 Byte kostete also 1 Byte, und
# 25 GiB am Tag waren damit 26 Milliarden Marken: je eine Zeile in
# blob_marken und, wenn hochgeladen, je eine Datei im Lager — die Grenze fuer
# die Platte hielt, die fuer Zeilen und Dateien gab es nicht (Pruefung vom
# 14.10.2026, B4). Mit 1 MiB je Marke sind es hoechstens 25 600 Marken je
# Adresse am Tag. Das IST das Zaehlerdach, nur in derselben Einheit wie die
# Menge - ein zweiter Zaehler daneben haette dieselbe Zahl anders
# ausgedrueckt. Ein ehrlicher Nutzer merkt es nicht: hundert kleine Bilder am
# Tag kosten 100 MiB von 25 GiB. (Zeilen in blob_marken kostet eine Marke
# seit SV-1 keine mehr, siehe BLOB_STUNDE; das Dach gilt weiter fuer die
# Dateien im Lager.)
BLOB_MINDESTMENGE = int(os.getenv("BITDM_BLOB_MIN_CHARGE", 1024**2))

# fullmatch und kein `$`: `^...$` mit .match() nimmt auch eine Kennung mit
# angehaengtem Zeilenumbruch an ("a"*52 + "\n"), weil `$` VOR einem letzten
# \n passt. Beim Lager wurde daraus ein anderer Dateiname als der, den die
# Marke meinte.
BLOB_KENNUNG_MUSTER = re.compile(r"[a-z2-7]{52}")


def blob_geheimnis() -> bytes:
    """Das mit dem Lager geteilte Geheimnis.

    BEI JEDEM AUFRUF NEU GELESEN und nicht beim Start einmal. Wird es getauscht,
    genuegt sonst ein Neustart auf einer der beiden Seiten, um alle Uploads
    stillschweigend scheitern zu lassen — mit 403 beim Lager und ohne Hinweis
    darauf, woran es liegt.
    """
    aus_umgebung = os.getenv("BITDM_BLOB_SECRET")
    if aus_umgebung:
        return aus_umgebung.encode()
    return Path(
        os.getenv("BITDM_BLOB_SECRET_FILE", "/etc/bitdm/blob.secret")
    ).read_bytes().strip()


def blob_marke(kennung: str, groesse: int, ablauf: int) -> str:
    """Muss Zeichen fuer Zeichen zu marke_gueltig() in blob_server.py passen."""
    nachricht = f"{kennung}|{groesse}|{ablauf}".encode()
    return hmac.new(blob_geheimnis(), nachricht, hashlib.sha256).hexdigest()


def blob_menge_heute(user_id: str) -> int:
    """Was diese Adresse in den letzten 24 Stunden an Marken bekommen hat.

    Hoechstens 25 Zeilen ueber idx_blob_marken, siehe BLOB_STUNDE. Zeilen von
    vor dem 23.10.2026 (eine je Marke) zaehlen genauso; sie sind nach
    BLOB_FENSTER ohnehin weg.
    """
    seit = time.time() - BLOB_FENSTER
    return db.execute(
        "SELECT COALESCE(SUM(groesse), 0) FROM blob_marken WHERE user_id=? AND ts > ?",
        (user_id, seit),
    ).fetchone()[0]


def blob_menge_anrechnen(user_id: str, menge: int) -> None:
    """Rechnet eine ausgestellte Marke an: auf die Zeile der laufenden Stunde.

    Ruft NUR auf, wer die schreibsperre haelt, innerhalb von `with db:`.
    UPDATE vor INSERT und kein UNIQUE-Index: unter der Sperre schreibt niemand
    dazwischen, und ein eindeutiger Index muesste auf Bestandsdatenbanken erst
    gegen die alten Einzelzeilen durchgesetzt werden.
    """
    stunde = int(time.time() // BLOB_STUNDE) * BLOB_STUNDE
    cur = db.execute(
        "UPDATE blob_marken SET groesse = groesse + ? WHERE user_id=? AND ts=?",
        (menge, user_id, stunde),
    )
    if cur.rowcount == 0:
        db.execute(
            "INSERT INTO blob_marken (user_id, groesse, ts) VALUES (?,?,?)",
            (user_id, menge, stunde),
        )


# --------------------------------------------------------------------------- #
#  Adresse  <->  Identitaetsschluessel
# --------------------------------------------------------------------------- #

def encode_id(public_key_bytes: bytes) -> str:
    """32-Byte-Curve25519-Public-Key -> 56-stellige Adresse.

    35 Bytes (32 Schluessel + 3 Pruefsumme) gehen in Base32 glatt auf:
    7 Bloecke a 5 Byte -> exakt 56 Zeichen, nie ein '='-Padding. Die 3-Byte-
    Pruefsumme faengt Tippfehler mit 24 statt 16 Bit ab.
    """
    checksum = hashlib.sha256(public_key_bytes).digest()[:3]
    return base64.b32encode(public_key_bytes + checksum).decode("ascii").lower()


def decode_id(address: str) -> bytes:
    """Adresse -> 32-Byte-Public-Key. Wirft ValueError bei kaputter Pruefsumme."""
    s = address.strip().replace(" ", "").replace("-", "").upper()
    if len(s) != 56:
        raise ValueError("Adresse muss 56 Zeichen haben")
    try:
        raw = base64.b32decode(s)
    except Exception as exc:
        raise ValueError("keine gueltige Base32-Adresse") from exc
    key, checksum = raw[:32], raw[32:35]
    if hashlib.sha256(key).digest()[:3] != checksum:
        raise ValueError("Pruefsumme stimmt nicht — vertippt?")
    return key


def b64d(s: str) -> bytes:
    """Strenges base64. Wirft ValueError (binascii.Error) bei allem anderen.

    validate=True ist hier nicht Pedanterie. Ohne es wirft b64decode alles
    weg, was nicht im Alphabet steht, und dekodiert den Rest — aus
    200 000 Ausrufezeichen und vier echten Zeichen wurden drei Byte. Die
    Groessengrenze (MAX_CIPHERTEXT_BYTES) sah nur diese drei Byte, und
    weitergereicht wurde danach die ROHE Zeichenkette: 200 KB Muell pro Rahmen
    in die Leitung des Empfaengers (Audit 25.09.2026). Weitergereicht wird
    deshalb seither das neu kodierte Ergebnis, nie die Eingabe.
    """
    return base64.b64decode(s, validate=True)


def b64e(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


# --------------------------------------------------------------------------- #
#  Signaturpruefung  (XEdDSA ueber Curve25519 — wie libsignal signiert)
# --------------------------------------------------------------------------- #

def verify_signature(identity_key: bytes, message: bytes, signature: bytes) -> bool:
    """Prueft eine XEdDSA-Signatur gegen den Curve25519-Identitaetsschluessel.

    ACHTUNG, hier lag ein schwerer Fehler:
    Frueher wurde der Montgomery-Key fest mit set_sign_bit=False umgerechnet.
    Das ist falsch. Der Edwards-Punkt A zu einem Curve25519-Schluessel hat ein
    Vorzeichenbit (die x-Paritaet), das je Identitaet praktisch zufaellig ist.
    libsignal legt es beim Signieren in das oberste Bit der Signatur:

        signature[63] |= publicKey[31] & 0x80      (ecc/ed25519.dart:87)

    und holt es beim Pruefen von dort wieder heraus:

        A_ed[31]     |= signature[63] & 0x80       (ecc/ed25519.dart:110)
        signature[63] &= 0x7F                      (ecc/ed25519.dart:111)

    Mit fest gesetztem False wurden rund die HAELFTE aller gueltigen Signaturen
    abgelehnt — gemessen 19 von 40. Der Fehler haette sich als sporadisch
    fehlschlagende Anmeldung geaeussert, abhaengig davon, welchen Schluessel ein
    Nutzer zufaellig gezogen hat. Genau die Sorte Fehler, die man in Produktion
    monatelang jagt.
    """
    if len(identity_key) != 32 or len(signature) != 64:
        return False
    try:
        # Vorzeichenbit aus der Signatur holen ...
        sign_bit = bool(signature[63] & 0x80)
        # ... und aus der Signatur entfernen, bevor sie geprueft wird.
        clean_sig = signature[:63] + bytes([signature[63] & 0x7F])
        ed_pub = curve25519_pub_to_ed25519_pub(identity_key, sign_bit)
        return ed25519_verify(clean_sig, ed_pub, message)
    except Exception:
        return False


# --------------------------------------------------------------------------- #
#  Datenbank
# --------------------------------------------------------------------------- #

# device_id UEBERALL MIT VORGABE 1.
#
# Das ist die ganze Rueckwaertsvertraeglichkeit dieses Umbaus: ein Client, der
# nichts von Geraeten weiss, schreibt und liest Geraet 1, und alle bestehenden
# Zeilen sind bei der Wanderung (siehe wandere_auf_geraete) Geraet 1 geworden.
# Deshalb ist auch das ERSTE Geraet einer Adresse immer die feste 1 und keine
# Zufallszahl (MEHRGERAETE.md §1): waere es eine Zufallszahl, koennte ein
# alter Client eine frisch angelegte Adresse nie mehr erreichen.
SCHEMA = """
CREATE TABLE IF NOT EXISTS identities (
    user_id           TEXT NOT NULL,
    device_id         INTEGER NOT NULL DEFAULT 1,
    identity_key      BLOB NOT NULL,
    registration_id   INTEGER NOT NULL DEFAULT 0,
    signed_prekey_id  INTEGER NOT NULL,
    signed_prekey     BLOB NOT NULL,
    signed_prekey_sig BLOB NOT NULL,
    updated_at        REAL NOT NULL,
    push_endpoint     TEXT,
    -- Zeitpunkt der letzten erfolgreichen /ws-Anmeldung DIESES Geraets, fuer
    -- GERAET_TTL. Bleibt 0, bis sich das Geraet zum ersten Mal verbindet —
    -- siehe LEBENSZEICHEN, das genau deshalb nicht nackt darauf schaut.
    last_seen         REAL NOT NULL DEFAULT 0,
    -- Der LAST-RESORT-Kyber-Prekey dieses Geraets (PQXDH, siehe
    -- KYBER_SCHLUESSEL_LAENGE). Alle drei NULL heisst: das Geraet hat sich
    -- ohne Kyber angemeldet (App vor 2.0), /prekey laesst die Felder dann
    -- weg. Immer alle drei oder keines — register() laesst nichts anderes
    -- herein. Bestehende Datenbanken bekommen die Spalten in
    -- ergaenze_kyber_spalten().
    kyber_prekey_id   INTEGER,
    kyber_prekey      BLOB,
    kyber_prekey_sig  BLOB,
    PRIMARY KEY (user_id, device_id)
);

CREATE TABLE IF NOT EXISTS one_time_prekeys (
    user_id    TEXT NOT NULL,
    device_id  INTEGER NOT NULL DEFAULT 1,
    key_id     INTEGER NOT NULL,
    public_key BLOB NOT NULL,
    PRIMARY KEY (user_id, device_id, key_id),
    FOREIGN KEY (user_id, device_id)
        REFERENCES identities(user_id, device_id) ON DELETE CASCADE
);

-- Kyber-EINMALschluessel, gebaut wie one_time_prekeys: derselbe
-- Primaerschluessel (er ist zugleich der einzige Index, den /prekey und das
-- Zaehlen je Geraet brauchen), dieselbe Kaskade beim Loeschen des Geraets.
-- Zusaetzlich die Signatur, weil libsignal fuer JEDEN Kyber-Prekey eine
-- verlangt, auch fuer einen Einmalschluessel — anders als beim EC-Vorrat.
--
-- BEWUSST EINE rowid-TABELLE und nicht WITHOUT ROWID: eine Zeile ist rund
-- 1,7 KB, und SQLite empfiehlt WITHOUT ROWID nur fuer Zeilen unter einem
-- Zwanzigstel der Seite. Ausserdem zieht /prekey per rowid (DELETE ...
-- WHERE rowid = (SELECT rowid ... LIMIT 1) RETURNING), genau wie beim
-- EC-Vorrat — zwei Fassungen derselben Entnahme waeren zwei Gelegenheiten,
-- eine davon falsch zu machen.
--
-- Auf einer Datenbank von vor dem Mehrgeraete-Umbau wird die Tabelle hier
-- angelegt, BEVOR wandere_auf_geraete() `identities` neu baut. Das geht gut:
-- der Fremdschluessel nennt die Tabelle beim Namen, die Wanderung schaltet
-- foreign_keys vorher ab, und nach dem Umbenennen zeigt er auf die neue
-- `identities` mit (user_id, device_id). Geprueft in
-- test_kyber_kommt_auch_auf_die_aelteste_datenbank.
CREATE TABLE IF NOT EXISTS one_time_kyber_prekeys (
    user_id    TEXT NOT NULL,
    device_id  INTEGER NOT NULL DEFAULT 1,
    key_id     INTEGER NOT NULL,
    public_key BLOB NOT NULL,
    signature  BLOB NOT NULL,
    PRIMARY KEY (user_id, device_id, key_id),
    FOREIGN KEY (user_id, device_id)
        REFERENCES identities(user_id, device_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS queue (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    recipient        TEXT NOT NULL,
    recipient_device INTEGER NOT NULL DEFAULT 1,
    sender           TEXT NOT NULL,
    -- sender_device ist KEINE Zugabe: eine gepufferte Zeile wird spaeter
    -- zugestellt und muss dann "from_device" tragen. Ohne diese Spalte weiss
    -- der Server beim Nachzustellen nicht mehr, von welchem Geraet die
    -- Nachricht kam — und der Empfaenger kann sie keiner Sitzung zuordnen.
    sender_device    INTEGER NOT NULL DEFAULT 1,
    ciphertext       BLOB NOT NULL,
    ts               REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_queue_ts        ON queue(ts);

-- Ausgestellte Marken fuer das Zwischenlager. NUR fuer die Tagesmenge da.
--
-- Die Kennung steht hier ABSICHTLICH NICHT drin. Sie waere die Verbindung
-- zwischen einer Adresse und einer bestimmten Datei im Lager — und genau die
-- soll dieser Server nicht haben. Fuer eine Mengenrechnung reicht, wie viel
-- wann; wofuer, geht ihn nichts an.
--
-- Die Zeilen werden nach 24 Stunden weggeraeumt (purge_expired). Ein
-- Protokoll, das laenger lebt, als es gebraucht wird, ist ein Protokoll.
-- Die signierte Geraeteliste je Adresse (GERAETEABMELDUNG.md §8).
--
-- `liste` ist Zeichen fuer Zeichen das, was der Client unterschrieben hat —
-- nicht neu serialisiert. Nur so kann jeder Abrufer die Signaturen selbst
-- nachpruefen, und genau das ist der Punkt: dieser Server soll eine Abmeldung
-- weder faelschen noch zuruecknehmen koennen.
--
-- KEIN Fremdschluessel auf identities: die Liste gilt auch fuer Geraete, die
-- gerade keine Zeile haben (GERAET_TTL hat sie weggeraeumt, oder sie melden
-- sich nach einem Zuruecksetzen erst noch an).
CREATE TABLE IF NOT EXISTS geraetelisten (
    user_id        TEXT PRIMARY KEY,
    epoche         INTEGER NOT NULL,
    liste          TEXT NOT NULL,
    sig_identitaet BLOB NOT NULL,
    sig_geraet     BLOB NOT NULL,
    geaendert      REAL NOT NULL
);

-- Offene Beitrittsanfragen, hoechstens BEITRITTE_JE_ADRESSE fuer BEITRITT_TTL.
CREATE TABLE IF NOT EXISTS beitritte (
    user_id        TEXT NOT NULL,
    device_id      INTEGER NOT NULL,
    anfrage        TEXT NOT NULL,
    sig_identitaet BLOB NOT NULL,
    sig_geraet     BLOB NOT NULL,
    ts             REAL NOT NULL,
    PRIMARY KEY (user_id, device_id)
);

CREATE TABLE IF NOT EXISTS blob_marken (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id TEXT NOT NULL,
    groesse INTEGER NOT NULL,
    ts      REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_blob_marken ON blob_marken(user_id, ts);
"""

# "Zuletzt ein Lebenszeichen" — als SQL-Ausdruck, weil zwei Stellen ihn
# brauchen (der Janitor und die Verdraengung beim vollen Geraete-Deckel).
#
# WARUM NICHT NACKT `last_seen`: last_seen wird erst bei der ersten
# /ws-Anmeldung gesetzt. Auf 0 stehen damit ZWEI voellig lebendige Faelle —
# jede bei der Wanderung uebernommene Bestandszeile und jedes Geraet, das sich
# gerade registriert, aber noch nicht verbunden hat. Ein nacktes
# `last_seen < now - GERAET_TTL` haette Henriks bestehende Registrierung eine
# Stunde nach dem Aufspielen weggeraeumt (Janitor-Takt 3600 s) und jede frische
# Registrierung sofort wieder verdraengbar gemacht.
#
# updated_at ist der Zeitpunkt der letzten Registrierung und damit die richtige
# Untergrenze: ein Geraet, das sein Buendel erneuert, lebt.
LEBENSZEICHEN = "MAX(last_seen, updated_at)"

db: sqlite3.Connection

# EINE Transaktion zur Zeit auf der geteilten Verbindung.
#
# init_db legt genau eine Verbindung mit check_same_thread=False an. FastAPI
# fuehrt /health, /register und /prekey als `def` aus, also im Threadpool; die
# WebSocket-Seite und purge_expired laufen dagegen auf dem Event-Loop —
# nachgesehen mit set_trace_callback, das fuer die einen "AnyIO worker thread"
# meldet und fuer die anderen den Loop-Thread. Der Transaktionszustand haengt
# aber an der VERBINDUNG und nicht am Aufrufer. Ohne diese Sperre nahm der
# Rollback des einen Threads die noch nicht committete Arbeit des anderen mit,
# und das COMMIT des einen machte die halbfertige Arbeit des anderen dauerhaft.
# Beide Richtungen stehen als Test in test_relay.py:
# test_fremder_rollback_holt_den_ausgegebenen_prekey_nicht_zurueck und
# test_purge_committet_keine_halbfertige_registrierung — ohne die Sperre sind
# sie rot.
#
# KEIN await INNERHALB DER SPERRE. Gibt eine Koroutine die Kontrolle ab,
# waehrend sie die Sperre haelt, bleibt die naechste Koroutine auf demselben
# Thread in acquire() stehen — dann kommt der Loop nie zur ersten zurueck, und
# auch asyncio.wait_for greift nicht mehr, weil der Loop-Thread selbst
# blockiert. test_keine_sperre_ueber_ein_await haelt die Regel fest.
#
# Lock und nicht RLock: eine versehentlich verschachtelte Sperre soll
# auffallen. Mit RLock wuerde das innere `with db:` die aeussere Transaktion
# vorzeitig committen — genau der Fehler, den diese Sperre verhindern soll.
schreibsperre = threading.Lock()


def init_db(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)

    # Nachtraeglich hinzugekommene Spalten. `CREATE TABLE IF NOT EXISTS` laesst
    # eine bestehende Tabelle unangetastet — ohne diese Zeilen liefe ein
    # bereits laufender Relay nach dem Update in "no such column".
    vorhanden = {row[1] for row in conn.execute("PRAGMA table_info(identities)")}
    if "registration_id" not in vorhanden:
        conn.execute(
            "ALTER TABLE identities ADD COLUMN registration_id INTEGER NOT NULL DEFAULT 0"
        )
    if "push_endpoint" not in vorhanden:
        # Wohin angestossen wird, wenn der Empfaenger nicht verbunden ist.
        #
        # WAS HIER STEHT: eine UnifiedPush-Adresse, die der Verteiler auf dem
        # Telefon vergeben hat. Kein Google-Token, keine Geraetekennung — ein
        # Zufallsname auf einem Server, den der Nutzer selbst gewaehlt hat.
        #
        # WAS DAS TROTZDEM IST: eine dauerhafte Kennung neben der Adresse. Wer
        # diese Datenbank in die Hand bekaeme, koennte damit anstossen und so
        # pruefen, ob ein bestimmtes Geraet gerade erreichbar ist. Deshalb ist
        # Push abschaltbar, und beim Abschalten wird die Zeile geleert statt
        # bloss ignoriert.
        conn.execute("ALTER TABLE identities ADD COLUMN push_endpoint TEXT")

    # Die Warteschlange bekommt ihre beiden Geraetespalten per ALTER — ihr
    # Primaerschluessel ist die AUTOINCREMENT-Kennung und wird nicht angefasst.
    # DEFAULT 1 heisst: alles, was heute drin liegt, ist Post an und von
    # Geraet 1 und bleibt zustellbar.
    q_spalten = {row[1] for row in conn.execute("PRAGMA table_info(queue)")}
    if "recipient_device" not in q_spalten:
        conn.execute("ALTER TABLE queue ADD COLUMN "
                     "recipient_device INTEGER NOT NULL DEFAULT 1")
    if "sender_device" not in q_spalten:
        conn.execute("ALTER TABLE queue ADD COLUMN "
                     "sender_device INTEGER NOT NULL DEFAULT 1")

    # NACH dem ALTER, sonst gibt es die Spalte beim ersten Start noch nicht.
    # Der alte Index auf `recipient` allein faellt weg: jede Abfrage der
    # Warteschlange fragt ab jetzt nach (Adresse, Geraet), und ein zweiter
    # Index auf die Praefixspalte kostet nur Schreibarbeit.
    conn.execute("DROP INDEX IF EXISTS idx_queue_recipient")

    # Die Deckel je Absender (schaffe_platz) zaehlen je (Empfaenger, Geraet,
    # Absender) und je Absender. Ohne diese beiden Indizes liefe jede
    # gepufferte Nachricht ueber die ganze Tabelle — genau unter der Flut,
    # gegen die die Deckel gebaut sind.
    #
    # idx_queue_paar ersetzt idx_queue_empfaenger: dessen Spalten sind sein
    # Praefix, jede Abfrage nach (recipient, recipient_device) nimmt ihn
    # genauso, und ein zweiter Index kostet nur Schreibarbeit. ERST anlegen,
    # DANN den alten wegwerfen — dazwischen darf es keinen Moment ohne Index
    # geben. Beides ist auf der laufenden Datenbank unbedenklich: CREATE INDEX
    # IF NOT EXISTS ist bei jedem Start ein Nichts, und beim ersten Start nach
    # dem Update dauert es bei einigen tausend Zeilen Millisekunden.
    conn.execute("CREATE INDEX IF NOT EXISTS idx_queue_paar "
                 "ON queue(recipient, recipient_device, sender)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_queue_absender "
                 "ON queue(sender)")
    conn.execute("DROP INDEX IF EXISTS idx_queue_empfaenger")
    # Fuer das Aufraeumen nach Zeit (purge_expired). Der bestehende Index
    # beginnt mit user_id und hilft dort nicht. Angelegt wurde er fuer die
    # Summe ueber den ganzen Relay; die gibt es seit SV-2 nicht mehr.
    conn.execute("CREATE INDEX IF NOT EXISTS idx_blob_marken_ts "
                 "ON blob_marken(ts)")

    conn.commit()
    wandere_auf_geraete(conn)
    # NACH der Wanderung und nicht bei den ALTERs oben: wandere_auf_geraete
    # baut `identities` aus einer festen Spaltenliste neu. Kaemen die
    # Kyber-Spalten vorher dazu, fielen sie beim Neubau einer Datenbank von
    # vor dem Mehrgeraete-Umbau wieder weg, und der erste /register liefe in
    # "no such column".
    ergaenze_kyber_spalten(conn)
    ergaenze_spk_geraete_sig(conn)
    return conn


def ergaenze_spk_geraete_sig(conn: sqlite3.Connection) -> bool:
    """Die Spalte fuer die Geraeteschluessel-Signatur am signierten Prekey.

    Nullbar und ohne Vorgabe, wie die Kyber-Spalten: das ALTER beruehrt keine
    Zeile. NULL heisst "nicht signiert" (App vor 2.0.1 oder Adresse ohne
    Liste), /prekey laesst das Feld dann weg. Aus demselben Grund NACH
    wandere_auf_geraete wie ergaenze_kyber_spalten. Rueckgabe: ob etwas zu
    tun war.
    """
    vorhanden = {row[1] for row in conn.execute("PRAGMA table_info(identities)")}
    if "spk_geraete_sig" in vorhanden:
        return False
    conn.execute("ALTER TABLE identities ADD COLUMN spk_geraete_sig BLOB")
    conn.commit()
    return True


def spk_nachricht(user_id: str, geraet: int, spk_id: int, spk_b64: str) -> bytes:
    """Was der Geraeteschluessel am signierten Prekey unterschreibt.

    Dieselben Zeichen baut die App in geraeteliste.dart (spkNachricht). Der
    Prekey steht als base64 darin, so wie /prekey ihn ausliefert — der Relay
    gibt ihn kanonisch kodiert aus, und so kodiert ihn die App beim Anmelden.
    """
    return PREKEY_PRAEFIX + f"{user_id}\n{geraet}\n{spk_id}\n{spk_b64}".encode()


def ergaenze_kyber_spalten(conn: sqlite3.Connection) -> bool:
    """Die drei Last-Resort-Spalten in eine bestehende `identities` holen.

    Per ALTER und nicht per Neuanlage wie bei wandere_auf_geraete: der
    Primaerschluessel bleibt, wie er ist, und eine nullbare Spalte ohne
    Vorgabe kostet SQLite beim ALTER nur einen Eintrag im Schema — keine
    Zeile wird angefasst, auch bei 250 000 Geraeten nicht. Jede bestehende
    Zeile hat danach NULL in allen drei Spalten, und das heisst "Geraet ohne
    Kyber": /prekey gibt fuer sie keine Kyber-Felder aus, bis das Geraet sich
    mit einer neuen App erneut anmeldet. Niemand verliert seine Registrierung.

    Die Tabelle one_time_kyber_prekeys braucht hier nichts: CREATE TABLE IF
    NOT EXISTS in SCHEMA legt sie bei jedem Start an, wenn sie fehlt.

    In EINER Transaktion: faellt der Start zwischen der ersten und der dritten
    Spalte um, bleibt keine halbe Erweiterung zurueck. Das BEGIN steht von
    Hand da, weil Pythons sqlite3 vor DDL keine Transaktion oeffnet — ohne es
    committete jedes ALTER fuer sich (dieselbe Falle, die wandere_auf_geraete
    mit BEGIN im Skript umgeht). Rueckgabe: ob etwas zu tun war.
    """
    vorhanden = {row[1] for row in conn.execute("PRAGMA table_info(identities)")}
    typen = {"kyber_prekey_id": "INTEGER", "kyber_prekey": "BLOB",
             "kyber_prekey_sig": "BLOB"}
    fehlend = [s for s in typen if s not in vorhanden]
    if not fehlend:
        return False
    conn.commit()
    conn.execute("BEGIN")
    try:
        for spalte in fehlend:
            conn.execute(f"ALTER TABLE identities ADD COLUMN {spalte} {typen[spalte]}")
        conn.commit()
    except sqlite3.Error:
        conn.rollback()
        raise
    print("[i] Datenbank um Kyber-Prekeys erweitert — bestehende Geraete "
          "stehen ohne Kyber da, bis sie sich neu anmelden")
    return True


def wandere_auf_geraete(conn: sqlite3.Connection) -> bool:
    """Bestehende Datenbank auf "je Adresse UND Geraet" umstellen.

    WAS BEIM AUFSPIELEN PASSIERT, in einem Satz: alle bestehenden Zeilen werden
    Geraet 1 und bleiben sonst Byte fuer Byte, wie sie waren. Ein heute
    registrierter Client, der nichts von Geraeten weiss, funktioniert danach
    unveraendert weiter — er schreibt und liest Geraet 1, weil jede Vorgabe im
    Protokoll 1 ist. Niemand verliert seine Registrierung, niemand muss sich
    neu anmelden, keine Sitzung wird ungueltig.

    WARUM NEUANLAGE UND KOPIE statt ALTER TABLE: `identities` hatte
    `user_id TEXT PRIMARY KEY`, und ein Primaerschluessel ist in SQLite per
    ALTER nicht erweiterbar — mit dem alten Schluessel liesse sich ein zweites
    Geraet gar nicht einfuegen. Dasselbe gilt fuer `one_time_prekeys`
    (PRIMARY KEY (user_id, key_id)), das zusaetzlich den neuen
    zusammengesetzten Fremdschluessel braucht.

    `blob_marken` bleibt ausdruecklich unangetastet, siehe blob_menge_heute.

    ABWEICHUNG VON MEHRGERAETE.md §8, UND SIE IST NOETIG: dort steht, jede
    uebernommene Zeile bekomme `last_seen = 0`. Zusammen mit §7 ("der janitor
    loescht Geraetezeilen mit last_seen < now - GERAET_TTL") loescht das JEDE
    Bestandsregistrierung beim ersten Aufraeumen. Auch mit LEBENSZEICHEN, das
    ersatzweise auf `updated_at` schaut, bleibt eine Luecke: `updated_at` ist
    der Zeitpunkt der letzten REGISTRIERUNG, nicht des letzten Besuchs. Ein
    Telefon, das taeglich verbindet, aber seit einem halben Jahr genug
    Einmalschluessel hat, traegt dort ein halbes Jahr altes Datum.

    Gemessen am 30.07.2026 gegen den echten Serverstart: eine Bestandszeile mit
    `updated_at = 1_700_000_000` (Nov 2023) war nach dem ersten Hochfahren weg,
    `/health` meldete `users: 0` — die Wanderung rettete die Zeile, und
    raeume_vergessene_geraete loeschte sie zwei Zeilen spaeter wieder.

    Deshalb bekommt jede uebernommene Zeile den Zeitpunkt der WANDERUNG als
    Lebenszeichen. Damit hat jedes Bestandsgeraet nach dem Aufspielen die
    vollen GERAET_TTL Zeit, sich einmal zu melden — genau die Zusage
    "bestehende Zeilen bleiben erhalten, bis das Geraet sich neu meldet".
    """
    vorhanden = {row[1] for row in conn.execute("PRAGMA table_info(identities)")}
    if "device_id" in vorhanden:
        return False

    # MUSS VOR BEGIN STEHEN: innerhalb einer Transaktion ist dieses PRAGMA
    # wirkungslos, und mit eingeschalteten Fremdschluesseln raeumte das
    # `DROP TABLE identities` unten per Kaskade genau die Einmalschluessel weg,
    # die gerade kopiert worden sind.
    conn.commit()
    conn.execute("PRAGMA foreign_keys=OFF")
    try:
        # BEGIN steht IM Skript und nicht davor: executescript committet eine
        # offene Transaktion vor dem Lauf und fuehrt selbst keine ein — ein
        # `conn.execute("BEGIN")` davor waere sofort wieder weg gewesen, und
        # jede DDL-Zeile haette einzeln committet. Ein Absturz mitten in der
        # Wanderung haette dann eine halb umgestellte Datenbank hinterlassen.
        conn.executescript("""
            BEGIN;
            CREATE TABLE identities_neu (
                user_id           TEXT NOT NULL,
                device_id         INTEGER NOT NULL DEFAULT 1,
                identity_key      BLOB NOT NULL,
                registration_id   INTEGER NOT NULL DEFAULT 0,
                signed_prekey_id  INTEGER NOT NULL,
                signed_prekey     BLOB NOT NULL,
                signed_prekey_sig BLOB NOT NULL,
                updated_at        REAL NOT NULL,
                push_endpoint     TEXT,
                last_seen         REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (user_id, device_id)
            );
            INSERT INTO identities_neu (user_id, device_id, identity_key,
                registration_id, signed_prekey_id, signed_prekey,
                signed_prekey_sig, updated_at, push_endpoint, last_seen)
            SELECT user_id, 1, identity_key, registration_id, signed_prekey_id,
                   signed_prekey, signed_prekey_sig, updated_at, push_endpoint, 0
            FROM identities;

            CREATE TABLE otk_neu (
                user_id    TEXT NOT NULL,
                device_id  INTEGER NOT NULL DEFAULT 1,
                key_id     INTEGER NOT NULL,
                public_key BLOB NOT NULL,
                PRIMARY KEY (user_id, device_id, key_id),
                FOREIGN KEY (user_id, device_id)
                    REFERENCES identities(user_id, device_id) ON DELETE CASCADE
            );
            INSERT INTO otk_neu (user_id, device_id, key_id, public_key)
            SELECT user_id, 1, key_id, public_key FROM one_time_prekeys;

            DROP TABLE one_time_prekeys;
            DROP TABLE identities;
            ALTER TABLE identities_neu RENAME TO identities;
            ALTER TABLE otk_neu        RENAME TO one_time_prekeys;
        """)
        # Der Zeitpunkt der Wanderung als Lebenszeichen — Begruendung oben.
        # Als eigene Anweisung, weil executescript keine Platzhalter kennt und
        # eine hineingeschriebene Zahl in einem Schema-Skript nichts zu suchen
        # hat. Steht noch IN der Transaktion, faellt also mit ihr zurueck.
        # Zu diesem Zeitpunkt enthaelt `identities` ausschliesslich
        # uebernommene Zeilen; spaeter registrierte trifft es nie.
        conn.execute("UPDATE identities SET last_seen=?", (time.time(),))
        # Muss leer sein. Bliebe ein Einmalschluessel ohne seine Geraetezeile
        # zurueck, waere das mit wieder eingeschalteten Fremdschluesseln eine
        # Datenbank, die sich nicht mehr aufraeumen laesst.
        kaputt = conn.execute("PRAGMA foreign_key_check").fetchall()
        if kaputt:
            raise sqlite3.IntegrityError(
                f"Wanderung haette {len(kaputt)} verwaiste Zeilen hinterlassen")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.execute("PRAGMA foreign_keys=ON")
    print("[i] Datenbank auf Mehrgeraete umgestellt — alle bestehenden "
          "Zeilen sind jetzt Geraet 1")
    return True


def loesche_geraet(uid: str, geraet: int) -> tuple[int, int]:
    """Eine Geraetezeile samt ihrer Post entfernen.

    Rueckgabe: (geloeschte Warteschlangenzeilen, geloeschte Kyber-
    Einmalschluessel) — beide Zahlen fuehren einen mitgezaehlten Stand
    (_queue_zeilen, _kyber_zeilen), und der Aufrufer schreibt sie erst NACH
    dem Commit fort.

    Die EC-Einmalschluessel nimmt die Kaskade. Die Warteschlange NICHT — sie
    zeigt auf keine Geraetezeile und wuerde sonst als Post an ein Geraet
    liegenbleiben, das es nicht mehr gibt, bis QUEUE_TTL_SECONDS sie holt.

    DIE KYBER-EINMALSCHLUESSEL WERDEN AUSDRUECKLICH GELOESCHT, obwohl die
    Kaskade sie auch naehme. Zwei Gruende: erstens braucht KYBER_OTK_MAX_GESAMT
    die Zahl, und die liefert nur ein eigenes DELETE (rowcount zaehlt keine
    Kaskadenzeilen). Zweitens haengt die Kaskade an `PRAGMA foreign_keys=ON`,
    und das gilt je VERBINDUNG — wer mit einem eigenen sqlite3-Aufruf an die
    Datenbank geht, hat es aus (durchstich_zwischenlager.py raeumt deshalb
    ebenfalls von Hand). Bei 1,7 KB je Zeile ist eine Waise kein
    Schoenheitsfehler, sondern Platte, die nie wieder frei wird.

    Ruft NUR auf, wer die schreibsperre schon haelt.
    """
    cur = db.execute("DELETE FROM queue WHERE recipient=? AND recipient_device=?",
                     (uid, geraet))
    weg = cur.rowcount
    kyber_weg = db.execute(
        "DELETE FROM one_time_kyber_prekeys WHERE user_id=? AND device_id=?",
        (uid, geraet)).rowcount
    db.execute("DELETE FROM identities WHERE user_id=? AND device_id=?",
               (uid, geraet))
    return weg, kyber_weg


def raeume_vergessene_geraete() -> int:
    """Geraete ohne Lebenszeichen seit GERAET_TTL entfernen. Rueckgabe: Anzahl.

    Ein Geraet, das nie wieder kommt, heilte frueher allein durch
    QUEUE_TTL_SECONDS. Das reicht nicht mehr: solange seine Zeile lebt, hat es
    eine eigene Warteschlange, die dauerhaft am Deckel steht — und ab da faellt
    fuer jeden Absender an dieses Geraet die aelteste Zeile weg. Ein totes
    Telefon macht die Adresse damit teilweise unbeschickbar.
    """
    cutoff = time.time() - GERAET_TTL
    # Nie per /ws angemeldet (last_seen = 0) und seit NIE_VERBUNDEN_TTL nicht
    # neu registriert: das war keine App (SV-3, siehe NEUE_ADRESSEN_JE_TAG).
    # Bestandszeilen von vor dem Mehrgeraete-Umbau trifft es nicht, sie
    # tragen den Zeitpunkt der Wanderung (wandere_auf_geraete).
    nie_cutoff = time.time() - NIE_VERBUNDEN_TTL
    entfernte_zeilen = 0
    entfernte_kyber = 0
    with schreibsperre:
        with db:
            tot = db.execute(
                f"SELECT user_id, device_id FROM identities WHERE {LEBENSZEICHEN} < ?"
                f" OR (last_seen = 0 AND updated_at < ?)",
                (cutoff, nie_cutoff),
            ).fetchall()
            for uid, geraet in tot:
                q, k = loesche_geraet(uid, geraet)
                entfernte_zeilen += q
                entfernte_kyber += k
        # Nach dem Commit, aber noch unter der Sperre: register() liest den
        # Kyber-Stand unter derselben Sperre und soll keinen sehen, der der
        # Tabelle vorauslaeuft.
        kyber_zeilen_aendern(-entfernte_kyber)
    queue_zeilen_aendern(-entfernte_zeilen)
    return len(tot)


def purge_expired() -> int:
    """Entfernt abgelaufene Warteschlangeneintraege. Rueckgabe: Anzahl."""
    cutoff = time.time() - QUEUE_TTL_SECONDS
    with schreibsperre, db:
        cur = db.execute("DELETE FROM queue WHERE ts < ?", (cutoff,))
        # Marken-Zeilen aelter als die Tagesfrist zaehlen fuer nichts mehr.
        # Sie stehenzulassen hiesse, ein Protokoll darueber zu fuehren, wer
        # wann wie viel abgelegt hat — ohne dass es noch einem Zweck diente.
        db.execute("DELETE FROM blob_marken WHERE ts < ?",
                   (time.time() - BLOB_FENSTER,))
    return cur.rowcount


# --------------------------------------------------------------------------- #
#  Ratenbegrenzung  (Token-Bucket je IP-Gruppe bzw. je Adresse)
# --------------------------------------------------------------------------- #

# Schluessel -> (Marken, zuletzt, voll_ab).
#
# `voll_ab` ist der Zeitpunkt, ab dem der Eimer wieder randvoll waere. Ein
# voller Eimer ist von einem fehlenden nicht zu unterscheiden (_take legt
# einen fehlenden voll an) — ab `voll_ab` darf der Eintrag also weg, ohne
# dass sich fuer irgendwen etwas aendert. So rechnet jede Familie ihre eigene
# Frist: "msg:" ist nach 30 s wieder voll, "otk:" erst nach 100 s — genau die
# Falle, vor der der Kommentar an msg_limit_ok warnt, faellt damit weg.
_buckets: dict[str, tuple[float, float, float]] = {}

# Schuetzt _buckets und _nonces. Die HTTP-Endpunkte laufen im Threadpool, die
# WebSocket-Seite auf dem Event-Loop; ein Aufraeumlauf, der ueber die Tabelle
# geht, waehrend ein anderer Thread einfuegt, liefe sonst in "dictionary
# changed size during iteration". NICHT die schreibsperre: die gehoert der
# Datenbank, und eine Verschachtelung der beiden waere eine Verklemmung auf
# Vorrat. Kein await darunter, dieselbe Regel wie dort.
_speichersperre = threading.Lock()
_zuletzt_geraeumt = 0.0


def _raeume_speicher_auf(jetzt: float) -> None:
    """Wirft abgelaufene Nonces und wieder volle Eimer weg.

    Ruft NUR auf, wer _speichersperre haelt.
    """
    global _zuletzt_geraeumt, _nonce_zahl
    _zuletzt_geraeumt = jetzt
    for k in [k for k, v in _buckets.items() if v[2] <= jetzt]:
        del _buckets[k]
    zahl = 0
    for paar in list(_nonces):
        offen = [e for e in _nonces[paar] if e[1] > jetzt]
        if offen:
            _nonces[paar] = offen
            zahl += len(offen)
        else:
            del _nonces[paar]
    _nonce_zahl = zahl


def _vielleicht_aufraeumen(jetzt: float) -> None:
    """Aufraeumen, wenn der Takt um ist oder eine Tabelle gross wird.

    Ruft NUR auf, wer _speichersperre haelt.
    """
    seit = jetzt - _zuletzt_geraeumt
    if seit >= AUFRAEUM_TAKT or (
            seit >= 1.0
            and (len(_buckets) >= AUFRAEUM_AB or _nonce_zahl >= AUFRAEUM_AB)):
        _raeume_speicher_auf(jetzt)


def raeume_speicher_auf() -> None:
    """Fuer den Hintergrundtakt im lifespan: raeumt auch ohne Verkehr auf."""
    with _speichersperre:
        _raeume_speicher_auf(time.monotonic())


def speicher_hat_platz() -> bool:
    """Ob beide Tabellen noch unter SPEICHER_MAX liegen (nach dem Aufraeumen)."""
    with _speichersperre:
        jetzt = time.monotonic()
        _vielleicht_aufraeumen(jetzt)
        if len(_buckets) < SPEICHER_MAX and _nonce_zahl < SPEICHER_MAX:
            return True
        # Am Dach NOCH EINMAL aufraeumen, auch wenn der letzte Lauf keine
        # Sekunde her ist — aber nur hier, am seltenen Rand, nicht bei jeder
        # Anfrage.
        _raeume_speicher_auf(jetzt)
        return len(_buckets) < SPEICHER_MAX and _nonce_zahl < SPEICHER_MAX


def _take(key: str, capacity: float, refill: float, cost: float) -> bool:
    with _speichersperre:
        now = time.monotonic()
        _vielleicht_aufraeumen(now)
        eintrag = _buckets.get(key)
        if eintrag is None:
            # AM DACH GIBT ES KEINEN NEUEN EIMER. Abweisen ist die einzige
            # Antwort, die den Speicher nicht weiter fuellt; bestehende Eimer
            # (also die Nutzer, die schon da waren) arbeiten unveraendert
            # weiter. Nach dem naechsten Aufraeumen ist wieder Platz.
            if len(_buckets) >= SPEICHER_MAX:
                return False
            tokens, last = capacity, now
        else:
            tokens, last, _ = eintrag
        tokens = min(capacity, tokens + (now - last) * refill)
        ok = tokens >= cost
        if ok:
            tokens -= cost
        voll_ab = (now + (capacity - tokens) / refill) if refill > 0 else float("inf")
        _buckets[key] = (tokens, now, voll_ab)
        return ok


def _gib_zurueck(key: str, capacity: float, refill: float, cost: float) -> None:
    """Legt eine Marke zurueck, die _take genommen hat, deren Zweck aber nicht
    zustande kam. Nie ueber die Fassung hinaus."""
    with _speichersperre:
        eintrag = _buckets.get(key)
        if eintrag is None:
            # Weggeraeumt wird nur ein wieder voller Eimer (voll_ab): nichts
            # zu erstatten, und ein neuer Eintrag fuellte nur den Speicher.
            return
        now = time.monotonic()
        tokens, last, _ = eintrag
        tokens = min(capacity, tokens + (now - last) * refill + cost)
        voll_ab = (now + (capacity - tokens) / refill) if refill > 0 else float("inf")
        _buckets[key] = (tokens, now, voll_ab)


def rate_limit_ok(key: str, cost: float = 1.0) -> bool:
    """Grobes Missbrauchsnetz je IP."""
    return _take(key, float(RATE_CAPACITY), RATE_REFILL_PER_SEC, cost)


def otk_limit_ok(user_id: str) -> bool:
    """Schutz des One-Time-Prekey-Pools EINES Nutzers.

    Greift je Ziel-Adresse statt je Herkunft, weil der Drain-Angriff auf einen
    bestimmten Nutzer zielt und ein Angreifer die IP beliebig wechseln kann.
    """
    return _take(f"otk:{user_id}", float(OTK_CAPACITY), OTK_REFILL_PER_SEC, 1.0)


def msg_limit_ok(user_id: str) -> bool:
    """Bremse fuer das PUFFERN, je Absender.

    Anders als otk_limit_ok, das die Zieladresse schuetzt, haengt diese Bremse
    am Absender: gepuffert wird auf seine Veranlassung, und der Empfaenger, den
    er sich aussucht, kostet ihn nichts.

    Der Eintrag heisst "msg:<adresse>". Aufgeraeumt wird er erst, wenn er
    wieder voll waere (`voll_ab` in _buckets) — die Frist rechnet sich also je
    Familie von selbst, und niemand bekommt nach kurzer Pause einen frischen
    Eimer geschenkt.
    """
    return _take(f"msg:{user_id}", float(MSG_CAPACITY), MSG_REFILL_PER_SEC, 1.0)


def live_limit_ok(user_id: str) -> bool:
    """Bremse fuer das Live-Durchreichen an eine alte Gegenstelle. Siehe
    LIVE_CAPACITY — warum ein eigener Eimer und nicht msg_limit_ok."""
    return _take(f"live:{user_id}", float(LIVE_CAPACITY), LIVE_REFILL_PER_SEC, 1.0)


def client_ip(request: Request) -> str:
    """Client-IP hinter nginx.

    SEIT 23.10.2026 NICHT MEHR AUS DER KOPFZEILE (Audit vom 16.10.2026,
    SV-10). Hier stand `X-Forwarded-For`, erster Eintrag, gleich von wem die
    Verbindung kam - mit der Begruendung, der Dienst lausche nur auf
    127.0.0.1. Lauscht ein selbst betriebener Relay aber versehentlich ohne
    nginx nach aussen, genuegten `X-Forwarded-For: 127.0.0.1` und
    `X-BitDM-Onion: 1`, und jede Bremse je Herkunft war aus.

    Die Kopfzeile wertet uvicorn schon selbst aus, und zwar nur, wenn der
    unmittelbare Gegenueber nginx auf der Schleife ist (`--proxy-headers
    --forwarded-allow-ips 127.0.0.1` in der Unit, bei uvicorn ohnehin die
    Vorgabe). `request.client` ist dann die IP, die nginx eingetragen hat;
    von jedem anderen Gegenueber ist es dessen eigene. Damit gilt auch fuer
    kommt_ueber_onion: `X-BitDM-*` zaehlt nur, wenn die Verbindung wirklich
    ueber die Schleife kam.
    """
    return request.client.host if request.client else "unbekannt"


def _ist_schleife(ip: str) -> bool:
    try:
        return ipaddress.ip_address(ip).is_loopback
    except ValueError:
        return False


def kommt_ueber_onion(request: Request) -> bool:
    """Kam diese Anfrage ueber den Onion-vHost (deploy/onion/relay-onion.nginx)?

    ZWEI BEDINGUNGEN, und erst beide zusammen zaehlen:

    1. Die Kopfzeile `X-BitDM-Onion: 1`. Sie setzt NUR der Onion-vHost; der
       oeffentliche vHost setzt sie ausdruecklich leer (bitdm-relay-proxy.conf
       und die /ws-location in install-relay.sh), damit ein Client sie nicht
       selbst mitschicken kann.
    2. Die Herkunft ist die Schleife. Ueber Tor kommt JEDE Verbindung von
       127.0.0.1 (tor reicht an nginx auf dem Loopback weiter, nginx traegt
       $remote_addr als X-Forwarded-For ein). Ueber den oeffentlichen vHost
       steht dort die echte IP des Clients — die ist nie 127.0.0.1.

    Die zweite Bedingung haelt also auch dann, wenn die erste einmal versagt
    (vergessenes Leeren in einer neuen location): wer von aussen die
    Kopfzeile faelscht, bringt trotzdem seine eigene IP mit.
    """
    if request.headers.get("x-bitdm-onion") != "1":
        return False
    return _ist_schleife(client_ip(request))


# DER TOR-CIRCUIT ALS HERKUNFT (seit 14.10.2026). Mit
# `HiddenServiceExportCircuitID haproxy` (deploy/onion/torrc.snippet) schreibt
# tor jeder Verbindung eine PROXY-Kopfzeile voran, deren Absenderadresse im
# Netz fc00:dead:beef:4dad::/64 liegt und in den letzten 32 Bit die Kennung des
# Circuits traegt. nginx reicht sie als X-BitDM-Kreis durch (relay-onion.nginx).
# Ein Circuit ist kein Mensch — ein Tor-Client baut neue —, aber er ist das,
# was einer allein nicht beliebig schnell vervielfacht, und vor allem: zwei
# verschiedene Tor-Nutzer teilen sich keinen.
TOR_KREIS_NETZ = ipaddress.ip_network("fc00:dead:beef:4dad::/64")


def tor_kreis(request: Request) -> str | None:
    """Die Circuit-Kennung einer Onion-Anfrage — oder None.

    NUR fuer Anfragen, die [kommt_ueber_onion] besteht, und nur in der Form,
    die tor schreibt. Der oeffentliche vHost leert die Kopfzeile; und selbst
    wenn nicht, zaehlte sie dort nicht, weil die Herkunft dann keine Schleife
    ist.
    """
    if not kommt_ueber_onion(request):
        return None
    wert = request.headers.get("x-bitdm-kreis", "").strip()
    try:
        adresse = ipaddress.ip_address(wert)
    except ValueError:
        return None
    if adresse.version != 6 or adresse not in TOR_KREIS_NETZ:
        return None
    return f"kreis:{int(adresse) & 0xFFFFFFFF}"


def limit_schluessel(request: Request, v6_praefix: int = 64) -> str | None:
    """Wonach die Bremse je Herkunft zaehlt — oder None fuer "gar nicht".

    IPv6 JE /64. Ein Anschluss bekommt vom Anbieter mindestens ein /64,
    meist ein /56 oder /48; jede einzelne Adresse darin ist frei waehlbar.
    Je voller Adresse gezaehlt hatte ein Angreifer damit 2**64 frische
    Eimer — die Bremse war fuer IPv6 praktisch abgeschaltet und fuellte
    obendrein _buckets. Ein /64 ist die kleinste Einheit, die ein Anschluss
    nicht beliebig vervielfachen kann.

    ONION: je Tor-Circuit, wenn tor ihn mitteilt ([tor_kreis]); sonst None.
    Ueber Tor kommen ALLE von 127.0.0.1, eine Bremse je IP waere dort eine
    einzige gemeinsame Bremse fuer alle Tor-Nutzer — ein Stoerer sperrte damit
    alle anderen aus. Ohne Circuit greifen dort nur die Grenzen je Adresse
    (otk_limit_ok, msg_limit_ok, NONCE_PLAETZE), die Grenzen im Onion-vHost
    (limit_req/limit_conn), das Speicherdach (SPEICHER_MAX) und die Grenzen in
    tor selbst (HiddenServiceMaxStreams).

    [v6_praefix] ist fuer die Herkunft der Nonces (nonce_herkunft, SV-5):
    dort zaehlt ein ganzer Anschluss, nicht ein einzelnes /64.
    """
    if kommt_ueber_onion(request):
        return tor_kreis(request)
    ip = client_ip(request)
    try:
        adresse = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if adresse.version == 6:
        if adresse.ipv4_mapped is not None:
            return str(adresse.ipv4_mapped)
        return str(ipaddress.ip_network(f"{adresse}/{v6_praefix}", strict=False))
    return str(adresse)


def nonce_herkunft(request: Request) -> str:
    """Wem ein Challenge-Nonce gehoert: die Einteilung der Bremse, aber IPv6
    JE /48 (seit 23.10.2026, Audit vom 16.10.2026, SV-5).

    Je /64 gezaehlt hatte ein Stoerer mit einem einzigen Heimanschluss (/56,
    also 256 /64) muehelos die NONCE_HERKUENFTE = 16 Herkuenfte beisammen:
    128 fremde Nonces, und am Dach des Paares fiel das des Opfers. Je /48
    braucht er 16 Anschluesse. Fuer die Bremse selbst bleibt es beim /64 -
    dort wuerde ein /48 ganze Mobilfunknetze in einen Eimer werfen; hier
    teilen sich nur Challenges FUER DIESELBE ADRESSE einen Platz.

    NICHT GEWAEHLT: am Dach fremde Eintraege gar nicht mehr zu verdraengen.
    Dann haelte ein Stoerer das Dach mit 16 Herkuenften dauerhaft voll, und
    das Opfer bekaeme gar kein Nonce mehr - aus "gelegentlich" wuerde
    "dauerhaft".

    Ueber Tor ohne Circuit-Kennung teilen sich alle die Herkunft "onion" -
    das ist der Stand vor dem 14.10.2026, nicht schlechter.
    """
    return limit_schluessel(request, v6_praefix=48) or "onion"


def herkunft_ok(request: Request, familie: str, cost: float = 1.0) -> bool:
    """Die Bremse je Herkunft fuer einen HTTP-Endpunkt. Onion: immer ja."""
    schluessel = limit_schluessel(request)
    if schluessel is None:
        return True
    return rate_limit_ok(f"{familie}:{schluessel}", cost)


# Wann das Adressdach zuletzt gemeldet wurde (SV-3, DACH_WARNUNG_AB).
_dach_gemeldet: float | None = None


def _melde_das_dach(adressen: int) -> None:
    """Hoechstens einmal je Stunde ins Journal. Ohne Adresse, nur die Zahl."""
    global _dach_gemeldet
    jetzt = time.monotonic()
    if _dach_gemeldet is not None and jetzt - _dach_gemeldet < 3600:
        return
    _dach_gemeldet = jetzt
    print(f"[!] Adressdach zu {100 * adressen // IDENTITAETEN_MAX} % belegt "
          f"({adressen} von {IDENTITAETEN_MAX}) - wer fuellt es? "
          f"(BITDM_IDENTITIES_MAX, Audit SV-3)")


def _eimer_neuer_adressen(request: Request) -> list[tuple[str, float, float]]:
    """Aus welchen Eimern eine neue Adresse von hier zahlt: je Eintrag
    (Schluessel, Fassung, Nachfuellung je Sekunde).

    Je Herkunft, IPv6 je /48. Ueber den Onion-Dienst zuerst der Eimer des
    Circuits (wenn tor ihn nennt), dann der gemeinsame aller Tor-Nutzer.
    """
    tag = 24 * 3600.0
    eimer = []
    schluessel = limit_schluessel(request, v6_praefix=48)
    if schluessel is not None:
        eimer.append((f"neu:{schluessel}", float(NEUE_ADRESSEN_JE_TAG),
                      NEUE_ADRESSEN_JE_TAG / tag))
    if kommt_ueber_onion(request):
        eimer.append(("neu:onion", float(NEUE_ADRESSEN_ONION_JE_TAG),
                      NEUE_ADRESSEN_ONION_JE_TAG / tag))
    return eimer


def neue_adresse_ok(request: Request) -> bool:
    """Der enge Eimer fuer NEUE Adressen (SV-3, siehe NEUE_ADRESSEN_JE_TAG).

    Nimmt aus jedem Eimer der Herkunft eine Marke, oder aus keinem: scheitert
    der zweite (der gemeinsame Onion-Eimer), bekommt der erste seine Marke
    zurueck. Sonst kostete eine Absage doch eine Marke.

    NUR RUFEN, WENN DIE ADRESSE GLEICH ANGELEGT WIRD (register, direkt vor dem
    INSERT). Bis zum 24.10.2026 kam der Aufruf vor allen Pruefungen, und jede
    Registrierung, die danach noch scheiterte (Kyber, Geraeteliste,
    Adressdach), kostete die ganze Herkunft eine Marke: ein dauerhaft
    scheiternder Client hinter einer geteilten IPv4 (Carrier-Grade-NAT) hielt
    den Eimer fuer alle anderen dort leer.
    """
    genommen = []
    for schluessel, fassung, nachfuellung in _eimer_neuer_adressen(request):
        if not _take(schluessel, fassung, nachfuellung, 1.0):
            for zurueck in genommen:
                _gib_zurueck(*zurueck, 1.0)
            return False
        genommen.append((schluessel, fassung, nachfuellung))
    return True


def neue_adresse_zurueck(request: Request) -> None:
    """Erstattet die Marke von neue_adresse_ok, wenn die Adresse danach doch
    nicht angelegt wurde (das Buendel liess sich nicht speichern)."""
    for schluessel, fassung, nachfuellung in _eimer_neuer_adressen(request):
        _gib_zurueck(schluessel, fassung, nachfuellung, 1.0)


# --------------------------------------------------------------------------- #
#  Einmal-Nonces fuer Besitznachweise
# --------------------------------------------------------------------------- #

# Schluessel ist (Adresse, Geraet), nicht die Adresse allein.
#
# Ohne das Geraet im Schluessel holten sich zwei Geraete derselben Adresse
# gegenseitig das Nonce weg: das zweite /register/challenge ueberschriebe das
# erste, und die Registrierung des ersten Geraets scheiterte mit "kein
# gueltiges Nonce". Bei zwei Geraeten, die beim App-Start gleichzeitig
# nachliefern, waere das der Normalfall gewesen.
#
# Ein Client, der kein Geraet nennt, bekommt den Schluessel (Adresse, None) und
# kollidiert damit nie mit einem neuen.
#
# JE PAAR EINE LISTE von bis zu NONCE_PLAETZE offenen Nonces, jedes mit eigenem
# Ablauf (seit 25.09.2026, Begruendung bei NONCE_PLAETZE). Der Client schickt
# sein Nonce bei /register NICHT zurueck — das ist so ausgeliefert und bleibt
# so. register() probiert die Signatur deshalb gegen jedes offene Nonce des
# Paares; bei acht Plaetzen sind das hoechstens acht Pruefungen.
# JEDER EINTRAG TRAEGT SEINE HERKUNFT (seit 14.10.2026, siehe NONCE_HERKUENFTE):
# (Nonce, Ablauf, Herkunft), in der Reihenfolge der Ausgabe.
_nonces: dict[tuple[str, int | None], list[tuple[bytes, float, str]]] = {}
# Wie viele Nonces insgesamt in _nonces stehen — mitgefuehrt, damit das Dach
# nicht bei jeder Anfrage ueber alle Listen zaehlen muss.
_nonce_zahl = 0


class Ueberlastet(Exception):
    """Der Speicherdeckel ist erreicht; die Anfrage bekommt 503."""


def issue_nonce(user_id: str, device_id: int | None = None,
                herkunft: str = "") -> bytes:
    global _nonce_zahl
    nonce = secrets.token_bytes(32)
    with _speichersperre:
        jetzt = time.monotonic()
        _vielleicht_aufraeumen(jetzt)
        schluessel = (user_id, device_id)
        alt = _nonces.get(schluessel, [])
        offen = [e for e in alt if e[1] > jetzt]
        _nonce_zahl -= len(alt) - len(offen)
        eigene = sum(1 for e in offen if e[2] == herkunft)
        dach = NONCE_PLAETZE * NONCE_HERKUENFTE
        # Nur ein Eintrag, der NICHTS verdraengt, scheitert am Speicherdach.
        # Wer schon da ist, tauscht hoechstens ein altes Nonce gegen ein neues
        # und belegt damit nichts dazu.
        if eigene < NONCE_PLAETZE and len(offen) < dach and _nonce_zahl >= SPEICHER_MAX:
            if offen:
                _nonces[schluessel] = offen
            else:
                _nonces.pop(schluessel, None)
            raise Ueberlastet()
        # Voll: das AELTESTE faellt, nicht das neue. Das neue gehoert zu der
        # Anfrage, die gerade laeuft — ein ehrlicher Client schickt gleich
        # darauf sein /register. Zuerst innerhalb DIESER Herkunft: so trifft
        # ein Stoerer nur sich selbst.
        if eigene >= NONCE_PLAETZE:
            i = next(i for i, e in enumerate(offen) if e[2] == herkunft)
            del offen[i]
            _nonce_zahl -= 1
        elif len(offen) >= dach:
            del offen[0]
            _nonce_zahl -= 1
        offen.append((nonce, jetzt + NONCE_TTL_SECONDS, herkunft))
        _nonce_zahl += 1
        _nonces[schluessel] = offen
    return nonce


def offene_nonces(user_id: str, device_id: int | None = None,
                  herkunft: str | None = None) -> list[bytes]:
    """Die noch gueltigen Nonces dieses Paares, OHNE sie zu verbrauchen.

    Mit [herkunft] stehen deren eigene vorne: /register kommt fast immer von
    dort, wo die Challenge herkam, und findet sein Nonce dann sofort. Die
    anderen bleiben dahinter, damit ein Telefon, das zwischen den beiden
    Anfragen das Netz wechselt (WLAN -> Mobilfunk, IPv4 -> IPv6), nicht an
    seinem eigenen Nonce scheitert.
    """
    jetzt = time.monotonic()
    with _speichersperre:
        offen = [e for e in _nonces.get((user_id, device_id), []) if e[1] > jetzt]
    if herkunft is not None:
        offen.sort(key=lambda e: e[2] != herkunft)
    return [e[0] for e in offen]


def verbrauche_nonce(user_id: str, device_id: int | None, nonce: bytes) -> bool:
    """Nimmt GENAU DIESES Nonce heraus. False, wenn es nicht (mehr) da war.

    Erst NACH einer gueltigen Signatur gerufen. Frueher wurde das Nonce vor
    der Pruefung verbraucht — damit konnte jeder mit einem Unsinns-/register
    fuer eine fremde Adresse deren offenes Nonce wegwerfen. Jetzt verbraucht
    nur, wer es auch unterschreiben kann; jedes Nonce gilt weiterhin genau
    einmal (zwei gleichzeitige /register mit derselben Signatur: nur einer
    findet es hier noch vor).
    """
    global _nonce_zahl
    jetzt = time.monotonic()
    with _speichersperre:
        liste = _nonces.get((user_id, device_id))
        if not liste:
            return False
        for i, (n, ablauf, _) in enumerate(liste):
            if n == nonce:
                del liste[i]
                _nonce_zahl -= 1
                if not liste:
                    del _nonces[(user_id, device_id)]
                return ablauf > jetzt
        return False


# --------------------------------------------------------------------------- #
#  Datenmodelle
# --------------------------------------------------------------------------- #

class OneTimePreKey(BaseModel):
    key_id: int
    public_key: str                       # base64


def kyber_kennung_feld(**vorgabe):
    """Das Feld fuer eine Kyber-Kennung: int, 0 .. KYBER_KENNUNG_MAX, kein bool.

    strict=True aus demselben Grund wie bei geraete_feld(): `true` waere in
    lax mode die Kennung 1. Anders als bei key_id der EC-Einmalschluessel
    steht hier eine Obergrenze — das Feld ist neu, es gibt keine installierte
    App, deren Werte daran scheitern koennten, und ohne Grenze kaeme ab 2**63
    OverflowError beim Binden (siehe register()). Ein Wert ausserhalb gibt
    422 vom Modell, wie jede andere Typverletzung im Rumpf.
    """
    return Field(strict=True, ge=0, le=KYBER_KENNUNG_MAX, **vorgabe)


class OneTimeKyberPreKey(BaseModel):
    """Ein Kyber-Einmalschluessel. Anders als OneTimePreKey MIT Signatur —
    libsignal verlangt fuer jeden Kyber-Prekey im Buendel eine."""
    key_id: int = kyber_kennung_feld()
    public_key: str                       # base64, 1569 Byte (0x08 + 1568)
    signature: str                        # base64, 64 Byte XEdDSA


GERAET_MAX_KENNUNG = 2**31 - 1

# Die groesste Geraetekennung, die Signals offizielle libsignal (0.105) annimmt.
#
# `ProtocolAddress` wirft dort bei allem ausserhalb von 1..127. Apps vor 2.0.0
# (Dart-Nachbildung) vergaben fuer Zweitgeraete Zufallszahlen bis 2^31; die
# bleiben bis zum Stichtag erlaubt, damit sie sich weiter anmelden koennen. Wer
# aber MIT Kyber kommt, ist eine App ab 2.0.0 — und deren Kennung muss in
# libsignal passen, sonst kann keine Gegenstelle eine Sitzung zu diesem Geraet
# aufbauen. Eine solche Anmeldung waere ein Fehler der App und soll beim
# Anmelden auffallen (Befund vom 16.10.2026).
LIBSIGNAL_GERAET_MAX = 127


def geraetekennung_moeglich(wert) -> bool:
    """Kann es ein Geraet mit dieser Kennung ueberhaupt geben?

    Dieselben Grenzen wie geraete_feld() darunter, nur fuer die Wege, an denen
    kein pydantic-Modell steht: die Query von /ws und `to_device` im Rahmen.

    DIE OBERGRENZE IST KEINE KOSMETIK. `int()` und JSON kennen keine, die
    SQLite-Bindung schon: alles ab 2**63 wirft beim Binden OverflowError, und
    der faellt weder in `except ValueError` noch in die Fangliste der
    Hauptschleife. Ungefangen kappt er die Verbindung ohne Close-Frame und
    schreibt je Versuch 3690 Byte Traceback ins Log — im /ws-Handler VOR jeder
    Anmeldung und ohne Ratenbremse (gemessen 31.07.2026 gegen einen eigenen
    uvicorn: `ws://127.0.0.1:8611/ws?user_id=&device_id=9223372036854775808`,
    dreimal, Serverlog 12225 Byte).

    bool ist in Python ein int — deshalb die zweite Pruefung, dieselbe Falle
    wie bei geraete_feld() und der Groesse der Blob-Marke.
    """
    return (isinstance(wert, int) and not isinstance(wert, bool)
            and 1 <= wert <= GERAET_MAX_KENNUNG)


def geraete_feld():
    """Das Feld `device_id`, wie es in jedem Rumpf steht.

    strict=True ist hier nicht Kosmetik: `bool` IST in Python ein `int`, und
    pydantic machte `true` in lax mode klaglos zu `1` — der Kennung, die jedem
    Bestandsgeraet gehoert. Dieselbe Falle wie bei der Blob-Groesse und bei den
    Kennungen im Empfangsnachweis.

    Eine Funktion und keine geteilte Konstante: ein FieldInfo gehoert genau
    einem Feld, zwei Modelle bekommen zwei eigene.
    """
    return Field(default=None, strict=True, ge=1, le=GERAET_MAX_KENNUNG)


class PreKeyBundle(BaseModel):
    user_id: str
    identity_key: str                     # base64, Curve25519

    # WELCHES GERAET dieser Adresse. Optional, und das ist der ganze
    # Rueckwaertspfad: fehlt das Feld, ist es Geraet 1 — und weil es dann auch
    # in canonical_bytes fehlt, sind die signierten Bytes eines alten Clients
    # Byte fuer Byte die bisherigen.
    device_id: int | None = geraete_feld()

    # Bezeichnet das GERAET, nicht die Identitaet.
    #
    # Bei BitDM ist das die einzige Moeglichkeit zu bemerken, dass eine
    # Gegenstelle neu aufgesetzt wurde: der Identitaetsschluessel bleibt
    # derselbe, weil er aus der Seed-Phrase kommt, und die Adresse damit auch.
    # Wechselt die Nummer, sitzt am anderen Ende ein anderes Geraet — der
    # Client kann darauf hinweisen, statt es stillschweigend hinzunehmen.
    registration_id: int = 0

    signed_prekey_id: int
    signed_prekey: str                    # base64
    signed_prekey_sig: str                # base64
    # max_length wirkt VOR der Signaturpruefung und vor jedem Plattenzugriff:
    # pydantic weist ein zu grosses Bundle mit 422 ab, ohne dass der Server es
    # je verarbeitet. Siehe OTK_MAX_JE_BUENDEL.
    one_time_prekeys: list[OneTimePreKey] = Field(
        default_factory=list, max_length=OTK_MAX_JE_BUENDEL)

    # ── Kyber (PQXDH), seit 16.10.2026 ────────────────────────────────────
    #
    # ALLE VIER OPTIONAL, und das ist wie bei device_id der ganze
    # Rueckwaertspfad: eine App ohne Kyber schickt nichts davon, und ihre
    # kanonischen Bytes bleiben Zeichen fuer Zeichen die alten. Ob der Relay
    # eine solche Anmeldung noch annimmt, entscheidet kyber_pflicht().
    #
    # Der Last-Resort-Schluessel: Kennung, 1569 Byte (0x08 + 1568), Signatur
    # des Identitaetsschluessels ueber genau diese 1569 Byte. Er bleibt, bis
    # das Geraet ihn mit einer neuen Anmeldung ersetzt, und geht an jeden
    # Abrufer, wenn kein Einmalschluessel (mehr) da ist.
    kyber_prekey_id: int | None = kyber_kennung_feld(default=None)
    kyber_prekey: str | None = None       # base64
    kyber_prekey_sig: str | None = None   # base64
    # Der Einmalvorrat. max_length wirkt wie bei one_time_prekeys VOR jeder
    # Dekodierung und Signaturpruefung (422). Warum 50, steht bei
    # KYBER_OTK_MAX_JE_BUENDEL.
    one_time_kyber_prekeys: list[OneTimeKyberPreKey] = Field(
        default_factory=list, max_length=KYBER_OTK_MAX_JE_BUENDEL)

    def canonical_bytes(self) -> bytes:
        """Deterministische Serialisierung fuer die Signatur.

        Der Besitznachweis signiert Nonce UND Bundle-Inhalt. Wuerde nur das
        Nonce signiert, koennte ein Angreifer eine abgefangene gueltige
        Signatur mit einem eigenen Bundle kombinieren.

        registration_id gehoert mit hinein: sonst koennte ein Angreifer ein
        abgefangenes Bundle mit veraenderter Nummer erneut einreichen und beim
        Gegenueber den Eindruck eines Geraetewechsels erzeugen — oder einen
        echten Wechsel verbergen.

        device_id gehoert aus demselben Grund mit hinein, und der Schaden waere
        groesser: stuende die Kennung nur im Rumpf, koennte ein
        Weiterleitender sie aendern und DIESELBE Signatur weiterverwenden. Die
        Registrierung landete dann unter fremder Geraetenummer, ueberschriebe
        dort Buendel und signed_prekey und loeschte die Einmalschluessel des
        echten Geraets — ein stiller Uebernahmefall innerhalb einer Adresse,
        gegen den der Besitznachweis sonst nichts ausrichtet.

        NUR WENN GESETZT. Fehlt das Feld, fehlt es auch hier, und die Bytes
        eines Clients ohne Geraetekennung sind Byte fuer Byte die von vor dem
        Umbau. Das ist die ganze Rueckwaertsvertraeglichkeit von /register —
        geprueft von app/test/net/canonical_fixtures.json, dessen bestehende
        Faelle unveraendert bleiben MUESSEN.

        DIE KYBER-FELDER GEHOEREN EBENFALLS HINEIN (16.10.2026, mit der App
        so vereinbart, MEHRGERAETE.md §15). Zwar traegt jeder Kyber-Schluessel
        seine eigene Signatur — aber die belegt nur, dass er IRGENDWANN von
        dieser Identitaet kam, nicht, dass er zu DIESER Anmeldung gehoert.
        Jedes /prekey gibt signierte Kyber-Schluessel an jeden heraus. Stuenden
        die Felder nur im Rumpf, koennte ein Weiterleitender sie gegen alte,
        laengst verbrauchte Schluessel desselben Geraets tauschen (deren
        private Haelften die App geloescht hat — jede neue Sitzung mit dem
        Opfer scheiterte dann still), den Einmalvorrat mit Wiederholungen
        fuellen oder die Kyber-Felder ganz streichen, was das Geraet bis zur
        naechsten Anmeldung fuer jede neue App unerreichbar machte.

        Die Regel, Zeichen fuer Zeichen so in der App nachgebaut: NUR WENN
        `kyber_prekey` gesetzt ist, kommen vier Schluessel dazu —
        `kyber_prekey`, `kyber_prekey_id`, `kyber_prekey_sig` und
        `one_time_kyber_prekeys` als Liste von Tripeln [key_id, public_key,
        signature], nach key_id aufsteigend. Die Liste steht auch leer da
        (`[]`); "fehlt" heisst nur "kein kyber_prekey". So ist es EINE Frage,
        an der die Form haengt, und nicht vier. Ein Buendel mit Einmal- aber
        ohne Last-Resort-Schluessel weist register() ab, bevor diese Bytes
        ueberhaupt gebraucht werden.

        Die Strings gehen so hinein, wie sie im Rumpf stehen — nicht neu
        kodiert, genau wie bei den EC-Feldern: die App signiert, was sie
        schickt, und jede Aenderung unterwegs, auch eine andere Schreibweise
        derselben Bytes, bricht den Besitznachweis.
        """
        payload = {}
        if self.device_id is not None:
            # sort_keys sortiert ohnehin; hier steht es trotzdem vorne, damit
            # die Reihenfolge dieselbe ist wie im Dart-Gegenstueck, das in
            # Einfuegereihenfolge schreibt ("d" kommt vor "i").
            payload["device_id"] = self.device_id
        payload.update({
            "user_id": self.user_id,
            "identity_key": self.identity_key,
            "registration_id": self.registration_id,
            "signed_prekey_id": self.signed_prekey_id,
            "signed_prekey": self.signed_prekey,
            "signed_prekey_sig": self.signed_prekey_sig,
            "one_time_prekeys": sorted(
                ([k.key_id, k.public_key] for k in self.one_time_prekeys),
                key=lambda x: x[0],
            ),
        })
        if self.kyber_prekey is not None:
            payload.update({
                "kyber_prekey": self.kyber_prekey,
                "kyber_prekey_id": self.kyber_prekey_id,
                "kyber_prekey_sig": self.kyber_prekey_sig,
                "one_time_kyber_prekeys": sorted(
                    ([k.key_id, k.public_key, k.signature]
                     for k in self.one_time_kyber_prekeys),
                    key=lambda x: x[0],
                ),
            })
        return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()


class RegisterRequest(BaseModel):
    bundle: PreKeyBundle
    signature: str                        # base64, XEdDSA ueber nonce||sha256(bundle)
    # Der Geraeteschluessel ueber ANMELDE_PRAEFIX || nonce || sha256(bundle)
    # (in der neuen Form ANMELDE_PRAEFIX || registrier_nachricht(...)).
    # Nur verlangt, wenn die Adresse eine Geraeteliste hat (siehe register).
    # NICHT in canonical_bytes: die Bytes alter Clients bleiben, wie sie sind.
    geraete_signatur: str | None = Field(default=None, max_length=200)
    # Der Name, unter dem die App diesen Relay erreicht hat - gesetzt heisst:
    # signiert ist registrier_nachricht(relay, ...), nicht nonce || hash
    # (KR-2, siehe ANMELDUNG_WS_PRAEFIX). Fehlt bei Apps bis 2.0.0.
    relay: str | None = Field(default=None, max_length=253)
    # Der Geraeteschluessel ueber spk_nachricht(...) (GERAETEABMELDUNG.md
    # §12.5 a). Nur mit Liste geprueft und gespeichert; Kontakte pruefen ihn
    # selbst gegen die Liste. Ebenfalls NICHT in canonical_bytes.
    spk_geraete_sig: str | None = Field(default=None, max_length=200)


class ChallengeRequest(BaseModel):
    user_id: str
    # Muss zur device_id im spaeteren /register passen, sonst findet der
    # Besitznachweis sein Nonce nicht — siehe _nonces.
    device_id: int | None = geraete_feld()


class GeraetelisteRequest(BaseModel):
    # Die Liste als ZEICHENKETTE, genau die unterschriebenen Bytes. Als Objekt
    # geschickt muesste dieser Server sie neu serialisieren, und jede
    # Abweichung in der Schreibweise braeche die Signatur bei jedem Abrufer.
    liste: str = Field(max_length=LISTE_MAX_ZEICHEN)
    sig_identitaet: str = Field(max_length=200)
    sig_geraet: str = Field(max_length=200)


class BeitrittRequest(BaseModel):
    anfrage: str = Field(max_length=2048)
    sig_identitaet: str = Field(max_length=200)
    sig_geraet: str = Field(max_length=200)


# --------------------------------------------------------------------------- #
#  Geraeteliste lesen und pruefen  (GERAETEABMELDUNG.md §8)
# --------------------------------------------------------------------------- #

class Geraeteliste(NamedTuple):
    """Eine gepruefte Fassung. `geraete`: device_id -> Geraeteschluessel."""
    roh: str
    adresse: str
    epoche: int
    geraete: dict[int, bytes]
    unterzeichner: int
    sig_identitaet: bytes
    sig_geraet: bytes


class Beitritt(NamedTuple):
    roh: str
    adresse: str
    device_id: int
    schluessel: bytes
    sig_identitaet: bytes
    sig_geraet: bytes


def _ganzzahl(wert, unten: int, oben: int) -> bool:
    # bool ist in Python ein int — dieselbe Falle wie bei geraete_feld().
    return (isinstance(wert, int) and not isinstance(wert, bool)
            and unten <= wert <= oben)


def _ohne_doppelte_schluessel(paare):
    """object_pairs_hook fuer json.loads: ein Schluessel zweimal ist Absicht.

    json.loads nimmt sonst stillschweigend den letzten. Signiert waere dann
    eine Zeichenkette, die zwei Lesarten hat — und welche ein anderer Parser
    nimmt, ist nicht festgelegt.
    """
    d = {}
    for k, v in paare:
        if k in d:
            raise ValueError("Schluessel doppelt")
        d[k] = v
    return d


def kanonisch(obj) -> str:
    """Die eine Schreibweise, in der Listen und Anfragen unterschrieben werden."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def _lies_kanonisch(roh: str, felder: set[str]) -> dict:
    """JSON-Objekt mit genau diesen Feldern, in kanonischer Schreibweise. Sonst 400.

    KANONISCH WIRD VERLANGT UND NICHT HERGESTELLT. Wer eine andere Schreibweise
    unterschreibt, bekaeme sie hier sonst still umgeschrieben, und die
    Signatur passte danach bei keinem Abrufer mehr. Nur ASCII, weil Python
    Umlaute anders schreibt als Dart (\\u00fc gegen ü) — vorkommen duerfen sie
    ohnehin nirgends.
    """
    if not roh.isascii():
        raise HTTPException(400, "nicht kanonisch (nur ASCII)")
    try:
        obj = json.loads(roh, object_pairs_hook=_ohne_doppelte_schluessel)
    except (ValueError, RecursionError) as exc:
        raise HTTPException(400, "kein gueltiges JSON") from exc
    if not isinstance(obj, dict) or set(obj) != felder:
        raise HTTPException(400, "Felder passen nicht")
    if kanonisch(obj) != roh:
        raise HTTPException(400, "nicht kanonisch")
    if not _ganzzahl(obj["v"], 1, 1):
        raise HTTPException(400, "unbekannte Fassung")
    return obj


def _adresse_kanonisch(a) -> bool:
    if not isinstance(a, str):
        return False
    try:
        return encode_id(decode_id(a)) == a
    except ValueError:
        return False


def _schluessel_32(wert, name: str) -> bytes:
    try:
        roh = b64d(wert) if isinstance(wert, str) else b""
    except ValueError:
        roh = b""
    if len(roh) != 32:
        raise HTTPException(400, f"{name} muss 32 Byte sein")
    return roh


def _signatur_64(wert: str, name: str) -> bytes:
    try:
        roh = b64d(wert)
    except ValueError:
        roh = b""
    if len(roh) != SIGNATUR_LAENGE:
        raise HTTPException(400, f"{name} muss 64 Byte sein")
    return roh


def lies_liste(roh: str, sig_identitaet: str, sig_geraet: str) -> Geraeteliste:
    """Form der Liste pruefen und die Signatur des Identitaetsschluessels.

    Die Signatur des GERAETESCHLUESSELS prueft erst setze_geraeteliste: gegen
    welchen Schluessel, haengt an der gespeicherten Fassung (§8.3).
    """
    obj = _lies_kanonisch(
        roh, {"adresse", "epoche", "geraete", "unterzeichner", "v", "zeit"})
    if not _adresse_kanonisch(obj["adresse"]):
        raise HTTPException(400, "adresse ungueltig")
    if not _ganzzahl(obj["epoche"], 1, EPOCHE_MAX):
        raise HTTPException(400, "epoche ungueltig")
    if not _ganzzahl(obj["zeit"], 0, EPOCHE_MAX):
        raise HTTPException(400, "zeit ungueltig")
    eintraege = obj["geraete"]
    if not isinstance(eintraege, list) or not 1 <= len(eintraege) <= GERAETE_MAX:
        raise HTTPException(400, f"geraete: 1 bis {GERAETE_MAX} Eintraege")
    geraete: dict[int, bytes] = {}
    vorher = 0
    for e in eintraege:
        if not isinstance(e, list) or len(e) != 3:
            raise HTTPException(400, "geraete: Eintrag ist [device_id, schluessel, info]")
        kennung, schluessel, info = e
        # Bis 127, weil libsignal keine groessere Geraetekennung annimmt
        # (LIBSIGNAL_GERAET_MAX). Streng aufsteigend: eine Kennung zweimal
        # waere zweimal dasselbe Geraet mit zwei Schluesseln.
        if not _ganzzahl(kennung, 1, LIBSIGNAL_GERAET_MAX) or kennung <= vorher:
            raise HTTPException(400, "geraete: device_id 1..127, streng aufsteigend")
        vorher = kennung
        geraete[kennung] = _schluessel_32(schluessel, "geraete: schluessel")
        if not isinstance(info, str) or len(info) > GERAETE_INFO_MAX:
            raise HTTPException(400, "geraete: info zu lang")
        try:
            b64d(info)
        except ValueError as exc:
            raise HTTPException(400, "geraete: info ist kein base64") from exc
    # Zwei Eintraege mit demselben Schluessel waeren ein Geraet unter zwei
    # Kennungen — es koennte sich dann aussuchen, als welches es auftritt.
    if len(set(geraete.values())) != len(geraete):
        raise HTTPException(400, "geraete: Geraeteschluessel doppelt")
    # Der Unterzeichner steht in der neuen Liste — oder er meldet sich gerade
    # selbst ab und stand in der alten. Ob das zutrifft, kann erst
    # setze_geraeteliste mit der gespeicherten Fassung entscheiden.
    if not _ganzzahl(obj["unterzeichner"], 1, LIBSIGNAL_GERAET_MAX):
        raise HTTPException(400, "unterzeichner ungueltig")

    sig_i = _signatur_64(sig_identitaet, "sig_identitaet")
    sig_g = _signatur_64(sig_geraet, "sig_geraet")
    if not verify_signature(decode_id(obj["adresse"]),
                            LISTE_PRAEFIX + roh.encode("ascii"), sig_i):
        raise HTTPException(403, "sig_identitaet passt nicht zur Adresse")
    return Geraeteliste(roh, obj["adresse"], obj["epoche"], geraete,
                        obj["unterzeichner"], sig_i, sig_g)


def lies_beitritt(roh: str, sig_identitaet: str, sig_geraet: str) -> Beitritt:
    """Eine Beitrittsanfrage: Form und BEIDE Signaturen. Sonst 400/403.

    Der Identitaetsschluessel belegt die Woerter — ohne ihn koennte jeder
    fremde Adressen mit Anfragen zuschuetten. Der Geraeteschluessel belegt,
    dass der Anfragende den Schluessel hat, den er eingetragen haben will.
    """
    obj = _lies_kanonisch(
        roh, {"adresse", "device_id", "info", "nachweis", "schluessel", "v", "zeit"})
    if not _adresse_kanonisch(obj["adresse"]):
        raise HTTPException(400, "adresse ungueltig")
    if not _ganzzahl(obj["device_id"], 1, LIBSIGNAL_GERAET_MAX):
        raise HTTPException(400, "device_id 1..127")
    # Der Nachweis: HMAC mit dem Code, den das bestaetigende Geraet anzeigt
    # (§8.5). Dieser Server kennt den Code nicht und kann ihn nicht pruefen —
    # nur die Form. Pruefen tut das Mitglied, und nur so ist eine Anfrage, die
    # jemand mit den Woertern dazwischenschiebt, von der echten zu
    # unterscheiden.
    _schluessel_32(obj["nachweis"], "nachweis")
    if not _ganzzahl(obj["zeit"], 0, EPOCHE_MAX):
        raise HTTPException(400, "zeit ungueltig")
    if not isinstance(obj["info"], str) or len(obj["info"]) > GERAETE_INFO_MAX:
        raise HTTPException(400, "info zu lang")
    try:
        b64d(obj["info"])
    except ValueError as exc:
        raise HTTPException(400, "info ist kein base64") from exc
    schluessel = _schluessel_32(obj["schluessel"], "schluessel")
    sig_i = _signatur_64(sig_identitaet, "sig_identitaet")
    sig_g = _signatur_64(sig_geraet, "sig_geraet")
    nachricht = BEITRITT_PRAEFIX + roh.encode("ascii")
    if not verify_signature(decode_id(obj["adresse"]), nachricht, sig_i):
        raise HTTPException(403, "sig_identitaet passt nicht zur Adresse")
    if not verify_signature(schluessel, nachricht, sig_g):
        raise HTTPException(403, "sig_geraet passt nicht zum schluessel")
    return Beitritt(roh, obj["adresse"], obj["device_id"], schluessel, sig_i, sig_g)


def gespeicherte_liste(user_id: str) -> tuple[int, dict[int, bytes]] | None:
    """(Epoche, device_id -> Geraeteschluessel) der gespeicherten Fassung.

    Gelesen aus der gespeicherten Zeichenkette selbst — es gibt keine zweite
    Tabelle, die mit ihr auseinanderlaufen koennte. Fuenf Eintraege zu parsen
    kostet weniger als eine zweite Abfrage.
    """
    zeile = db.execute("SELECT epoche, liste FROM geraetelisten WHERE user_id=?",
                       (user_id,)).fetchone()
    if zeile is None:
        return None
    eintraege = json.loads(zeile[1])["geraete"]
    return zeile[0], {k: b64d(s) for k, s, _ in eintraege}


def geraeteliste_als_json(user_id: str) -> dict | None:
    """Die gespeicherte Fassung so, wie sie jeder Abrufer bekommt."""
    zeile = db.execute(
        "SELECT liste, sig_identitaet, sig_geraet FROM geraetelisten"
        " WHERE user_id=?", (user_id,)).fetchone()
    if zeile is None:
        return None
    return {"liste": zeile[0], "sig_identitaet": b64e(zeile[1]),
            "sig_geraet": b64e(zeile[2])}


def geraete_signatur_ok(schluessel: bytes, nachricht: bytes,
                        roh: object) -> bool:
    """Die zweite Unterschrift bei der Anmeldung, mit dem Geraeteschluessel."""
    try:
        sig = b64d(roh) if isinstance(roh, str) else b""
    except ValueError:
        return False
    return verify_signature(schluessel, ANMELDE_PRAEFIX + nachricht, sig)


def raeume_beitritte_auf() -> int:
    with schreibsperre, db:
        return db.execute("DELETE FROM beitritte WHERE ts < ?",
                          (time.time() - BEITRITT_TTL,)).rowcount


# --------------------------------------------------------------------------- #
#  App
# --------------------------------------------------------------------------- #

@asynccontextmanager
async def lifespan(app: FastAPI):
    global db
    # Zuerst, damit ein falscher Name im Journal oben steht (Befund 8 der
    # Nachpruefung vom 24.10.2026, siehe RELAY_NAME_LABEL).
    melde_relay_namen()
    db = init_db(DB_PATH)
    purged = purge_expired()
    if purged:
        print(f"[i] {purged} abgelaufene Nachrichten entfernt")
    # Auch beim Start und nicht nur stuendlich: ein Relay, das oefter neu
    # startet als einmal je Stunde, kaeme sonst nie zum Aufraeumen.
    vergessen = raeume_vergessene_geraete()
    if vergessen:
        print(f"[i] {vergessen} vergessene Geraete entfernt")
    # Ohne diese Zeile stuende der Zaehler nach einem Neustart auf 0 und
    # QUEUE_MAX_TOTAL waere wirkungslos, bis die erste Stunde um ist.
    queue_zeilen_neu_zaehlen()
    # Dasselbe fuer KYBER_OTK_MAX_GESAMT.
    kyber_zeilen_neu_zaehlen()

    async def janitor():
        while True:
            await asyncio.sleep(3600)
            try:
                purge_expired()
                # Abgelaufene Beitrittsanfragen. beantrage_beitritt raeumt
                # zwar bei jeder neuen Anfrage mit auf, aber eine Adresse, die
                # nie wieder anfragt, behielte ihre sonst fuer immer.
                raeume_beitritte_auf()
                vergessen = raeume_vergessene_geraete()
                if vergessen:
                    print(f"[i] {vergessen} vergessene Geraete entfernt")
                queue_zeilen_neu_zaehlen()
                kyber_zeilen_neu_zaehlen()
            except sqlite3.Error as exc:
                print(f"[!] Aufraeumen fehlgeschlagen: {exc}")

    async def speicherpflege():
        # Eigener, kurzer Takt fuer _nonces und _buckets. Ohne ihn raeumten
        # nur Anfragen auf — nach einer Flut, auf die kein Verkehr mehr folgt,
        # bliebe der Speicher bis zur naechsten Anfrage belegt.
        while True:
            await asyncio.sleep(AUFRAEUM_TAKT)
            raeume_speicher_auf()

    task = asyncio.create_task(janitor())
    pflege = asyncio.create_task(speicherpflege())
    try:
        yield
    finally:
        task.cancel()
        pflege.cancel()
        # Der gemeinsame Client der Anstoesse (SV-7) und seine Verbindungen.
        await schliesse_push_klient()
        # Ein Worker kann noch mitten in einer Transaktion stehen; ohne die
        # Sperre bekaeme er "Cannot operate on a closed database".
        with schreibsperre:
            db.close()


app = FastAPI(title="BitDM Relay", version="1.0", lifespan=lifespan)

# ZWEISTUFIG: Adresse -> Geraet -> Verbindung.
#
# Frueher stand hier eine Verbindung je Adresse, und eine neue verdraengte die
# alte mit 4409. Genau das ist der Fehler, den Mehrgeraete behebt: zwei Geraete
# mit denselben zwoelf Woertern warfen sich gegenseitig hinaus, und keines
# merkte etwas. Verdraengt wird ab jetzt nur noch bei gleichem
# (Adresse, Geraet) — eine zweite Verbindung DESSELBEN Geraets ist immer noch
# ein Neustart derselben App und soll die alte ersetzen.
connections: dict[str, dict[int, WebSocket]] = {}

# Ob die Verbindung hinter `connections[adresse]` den Empfangsnachweis
# beherrscht.
#
# GETRENNT GEFUEHRT, weil es der ABSENDER wissen muss, nicht der Empfaenger.
# Das Flag kommt in der Anmeldung der EMPFANGENDEN Verbindung an und lag
# bisher nur als lokale Variable in deren eigenem Aufruf; der Absender, der
# gleich entscheidet, ob er live durchreicht oder erst puffert, kam nie daran.
#
# Immer zusammen mit `connections` gesetzt und geloescht — zwei Verzeichnisse,
# die auseinanderlaufen koennen, waeren schlimmer als eines mit einem Tupel.
# Ein Tupel waere sauberer, aendert aber jede Fundstelle von `connections`.
nachweisfaehig: dict[str, dict[int, bool]] = {}

# Wie viele Zeilen in `queue` stehen — mitgefuehrt statt gezaehlt.
#
# WARUM NICHT EINFACH "SELECT COUNT(*) FROM queue" JE NACHRICHT: gemessen mit
# dem hier installierten SQLite 3.50.4 auf diesem Schema — 0,047 ms bei 100 000
# Zeilen, aber 2,3 ms bei 200 000, 5,0 ms bei 400 000 und 10,9 ms bei 800 000
# (der Zaehlvorgang laeuft ueber die Seiten von idx_queue_ts und wird teuer,
# sobald der Index nicht mehr in den Seitenpuffer passt). Jeder db-Aufruf in
# ws_endpoint laeuft synchron auf dem Event-Loop; diese Millisekunden treffen
# ALLE Verbindungen. Ein Riegel, der genau unter der Flut teuer wird, gegen die
# er gebaut ist, waere selbst der Angriff.
_queue_zeilen = 0


def queue_zeilen_neu_zaehlen() -> int:
    """Setzt den Zaehler gegen die Tabelle zurueck.

    Der Zaehler wird an zwei Stellen fortgeschrieben; jede davon kann
    danebenliegen, wenn eine Transaktion nicht durchgeht. Einmal je Stunde
    gegen die Wahrheit zu pruefen kostet einen Zaehlvorgang und begrenzt jeden
    Irrtum auf eine Stunde.
    """
    global _queue_zeilen
    with schreibsperre:
        _queue_zeilen = db.execute("SELECT COUNT(*) FROM queue").fetchone()[0]
    return _queue_zeilen


def queue_zeilen_aendern(delta: int) -> None:
    global _queue_zeilen
    _queue_zeilen = max(0, _queue_zeilen + delta)


# Wie viele Zeilen in `one_time_kyber_prekeys` stehen — mitgezaehlt fuer
# KYBER_OTK_MAX_GESAMT, aus demselben Grund wie _queue_zeilen.
#
# GEMESSEN am 16.10.2026: `SELECT COUNT(*)` ueber 100 000 Kyber-Zeilen
# braucht 8,5 ms, am Dach (500 000) also rund 40 ms. /register haelt dabei
# die schreibsperre, und die teilt sich die WebSocket-Seite auf dem
# Event-Loop — jede Anmeldung haelte alle Verbindungen 40 ms an. Gezaehlt wird
# deshalb nur beim Start und stuendlich im janitor; dazwischen schreiben die
# drei Stellen, die die Tabelle veraendern, den Stand fort: register(),
# get_prekey() und loesche_geraet() ueber seine Aufrufer.
#
# ANDERS ALS _queue_zeilen wird dieser Stand nur UNTER der schreibsperre und
# erst NACH dem Commit geaendert. register() entscheidet daran, wie viele
# Schluessel es noch annimmt; ein Stand, der der Tabelle vorauslaeuft oder
# nachhinkt, liesse das Dach durchlaessig werden oder zu frueh zugehen.
# Laeuft er trotzdem einmal daneben (eine Hand an der Datenbank, siehe
# durchstich_zwischenlager.py), heilt es der naechste janitor-Lauf.
_kyber_zeilen = 0


def kyber_zeilen_neu_zaehlen() -> int:
    """Setzt den Kyber-Stand gegen die Tabelle zurueck (Start, janitor)."""
    global _kyber_zeilen
    with schreibsperre:
        _kyber_zeilen = db.execute(
            "SELECT COUNT(*) FROM one_time_kyber_prekeys").fetchone()[0]
    return _kyber_zeilen


def kyber_zeilen_aendern(delta: int) -> None:
    """Ruft NUR auf, wer die schreibsperre haelt — nach dem Commit."""
    global _kyber_zeilen
    _kyber_zeilen = max(0, _kyber_zeilen + delta)


# Der Absender mit den meisten Zeilen in der ganzen Tabelle, zwischengemerkt:
# (absender, zeilen, monotonic-Zeitpunkt). Nur am Dach gebraucht.
#
# WARUM ZWISCHENGEMERKT: die Frage laeuft ueber den ganzen Index
# idx_queue_absender, bei 200 000 Zeilen einige Millisekunden — synchron auf
# dem Event-Loop. Am Dach steht der Relay genau dann, wenn jemand flutet, und
# ein Riegel, der je Rahmen teuer wird, waere selbst der Angriff (dieselbe
# Ueberlegung wie bei _queue_zeilen). Fuenf Sekunden alt darf die Antwort
# sein: der Schwerste von vor fuenf Sekunden ist auch jetzt noch schwer.
_schwerster: tuple[str, int, float] | None = None
SCHWERSTER_FRIST = 5.0


def _schwerster_absender() -> tuple[str, int] | None:
    """Ruft NUR auf, wer die schreibsperre schon haelt."""
    global _schwerster
    jetzt = time.monotonic()
    if _schwerster is not None and jetzt - _schwerster[2] < SCHWERSTER_FRIST:
        return _schwerster[0], _schwerster[1]
    zeile = db.execute(
        "SELECT sender, COUNT(*) AS n FROM queue GROUP BY sender"
        " ORDER BY n DESC LIMIT 1").fetchone()
    _schwerster = (zeile[0], zeile[1], jetzt) if zeile else None
    return (zeile[0], zeile[1]) if zeile else None


def _wirf_aelteste(bedingung: str, werte: tuple) -> int:
    """Die aelteste Zeile, auf die `bedingung` passt. Rueckgabe: 0 oder 1.

    Ruft NUR auf, wer die schreibsperre und die Transaktion schon haelt.
    """
    return db.execute(
        f"DELETE FROM queue WHERE id = (SELECT id FROM queue WHERE {bedingung}"
        f" ORDER BY id LIMIT 1)", werte).rowcount


def schaffe_platz(to: str, geraet: int, absender: str) -> bool:
    """Macht Platz fuer EINE neue Zeile von `absender` an (`to`, `geraet`).

    Rueckgabe True: das INSERT darf folgen. False: "Warteschlange voll".

    DER GRUNDSATZ (Audit vom 25.09.2026): fuer einen Absender faellt nie die
    Zeile eines ANDEREN, der weniger liegen hat als er. Frueher fiel bei
    vollem Geraet schlicht die aelteste Zeile — und ein Fremder, der die
    Adresse kennt, spuelte mit 500 Rahmen alles weg, was echte Kontakte dem
    abwesenden Opfer hinterlassen hatten.

    Die Reihenfolge der Pruefungen ist Absicht:

    1. PAAR VOLL (QUEUE_MAX_JE_PAAR): seine eigene aelteste Zeile an dieses
       Geraet faellt. Er verdraengt nur sich selbst. Nicht abgewiesen, aus
       demselben Grund, aus dem frueher geworfen statt abgewiesen wurde: ein
       totes Telefon am Deckel darf eine lebende Unterhaltung mit den anderen
       Geraeten derselben Adresse nicht mit "Warteschlange voll" stoeren.
    2. ABSENDER VOLL (QUEUE_MAX_JE_ABSENDER): abgewiesen. Wer 2000 Zeilen
       ueber alle Empfaenger liegen hat, flutet, und hier gibt es keine
       eigene Zeile, deren Wegfall die Sache besser machte.
    3. GERAET VOLL (QUEUE_MAX_PER_USER): es faellt die aelteste Zeile des
       Absenders, der bei DIESEM Geraet am meisten liegen hat — ist das der
       Absender selbst (oder hat er gleich viele), seine eigene. Ein
       Kontakt mit drei wartenden Nachrichten verliert damit erst etwas,
       wenn jeder andere Absender hoechstens drei liegen hat; dafuer
       braeuchte ein Angreifer bei 500 Plaetzen ueber 160 Adressen.
    4. TABELLE VOLL (QUEUE_MAX_TOTAL): ist ein ANDERER Absender schwerer als
       dieser, faellt dessen aelteste Zeile; sonst wird abgewiesen. Frueher
       wies das Dach JEDEN ab — ein einziger Flutender schaltete damit die
       Offline-Zustellung fuer alle ab. Jetzt trifft das Dach den, der es
       fuellt. Wer selbst der Schwerste ist, wird WEITER abgewiesen, sonst
       waere das Dach fuer ihn keines
       (test_das_dach_ueber_der_ganzen_tabelle_haelt).

    Fall 1 und 3 werfen genau eine Zeile fuer genau eine neue — die Tabelle
    waechst dabei nicht, deshalb stehen sie VOR dem Dach.
    """
    global _schwerster
    weg = 0
    try:
        with schreibsperre, db:
            paar = db.execute(
                "SELECT COUNT(*) FROM queue WHERE recipient=?"
                " AND recipient_device=? AND sender=?",
                (to, geraet, absender)).fetchone()[0]
            if paar >= QUEUE_MAX_JE_PAAR:
                weg = _wirf_aelteste(
                    "recipient=? AND recipient_device=? AND sender=?",
                    (to, geraet, absender))
                return True

            eigene = db.execute("SELECT COUNT(*) FROM queue WHERE sender=?",
                                (absender,)).fetchone()[0]
            if eigene >= QUEUE_MAX_JE_ABSENDER:
                return False

            offen = db.execute(
                "SELECT COUNT(*) FROM queue WHERE recipient=?"
                " AND recipient_device=?", (to, geraet)).fetchone()[0]
            if offen >= QUEUE_MAX_PER_USER:
                schwer = db.execute(
                    "SELECT sender, COUNT(*) AS n FROM queue"
                    " WHERE recipient=? AND recipient_device=?"
                    " GROUP BY sender ORDER BY n DESC, MIN(id) LIMIT 1",
                    (to, geraet)).fetchone()
                opfer = absender if schwer is None or paar >= schwer[1] else schwer[0]
                weg = _wirf_aelteste(
                    "recipient=? AND recipient_device=? AND sender=?",
                    (to, geraet, opfer))
                return True

            if _queue_zeilen >= QUEUE_MAX_TOTAL:
                schwer = _schwerster_absender()
                if schwer is None or schwer[0] == absender or schwer[1] <= eigene:
                    return False
                weg = _wirf_aelteste("sender=?", (schwer[0],))
                if weg == 0:
                    # Der Zwischenstand war veraltet: der vermeintlich
                    # Schwerste hat nichts mehr liegen. Beim naechsten Mal
                    # neu fragen, diesmal abweisen — das Dach gibt im Zweifel
                    # nicht nach.
                    _schwerster = None
                    return False
                if _schwerster is not None:
                    _schwerster = (_schwerster[0], _schwerster[1] - 1, _schwerster[2])
                return True
            return True
    finally:
        # AUSSERHALB der Sperre und nach dem Commit — dieselbe Regel wie bei
        # den anderen Stellen, die den Zaehler fortschreiben.
        queue_zeilen_aendern(-weg)


@app.get("/health")
def health():
    # `queued` heisst seit dem Empfangsnachweis "wartet auf einen abwesenden
    # Empfaenger ODER auf dessen Nachweis". Der Wert liegt im Mittel etwas
    # hoeher als vorher; wer darauf eine Schwelle gesetzt hat, muss das
    # wissen.
    #
    # `users` zaehlt weiterhin ADRESSEN und nicht Zeilen — sonst bedeutete die
    # Betriebszahl nach dem Mehrgeraete-Umbau etwas anderes als vorher und
    # jede darauf gesetzte Schwelle waere still falsch. Die Geraetezeilen
    # stehen daneben als `geraete`.
    users = db.execute("SELECT COUNT(DISTINCT user_id) FROM identities").fetchone()[0]
    geraete = db.execute("SELECT COUNT(*) FROM identities").fetchone()[0]
    queued = db.execute("SELECT COUNT(*) FROM queue").fetchone()[0]
    online = sum(len(g) for g in connections.values())
    return {"ok": True, "users": users, "geraete": geraete, "online": online,
            "queued": queued}


# ---------------------------------------------------------------- Registrieren

@app.post("/register/challenge")
def register_challenge(req: ChallengeRequest, request: Request):
    """Schritt 1 des Besitznachweises: Server gibt ein Einmal-Nonce aus."""
    if not herkunft_ok(request, "chal"):
        raise HTTPException(429, "zu viele Anfragen")
    try:
        decode_id(req.user_id)
    except ValueError as exc:
        raise HTTPException(400, f"ungueltige Adresse: {exc}") from exc
    # 503 und nicht 429: das ist keine Bremse gegen diesen Absender, sondern
    # ein Relay am Speicherdach (SPEICHER_MAX). Ein Client soll es spaeter
    # noch einmal versuchen, nicht an sich selbst zweifeln.
    if not speicher_hat_platz():
        raise HTTPException(503, "Relay ueberlastet, bitte spaeter erneut")
    try:
        nonce = issue_nonce(req.user_id, req.device_id, nonce_herkunft(request))
    except Ueberlastet as exc:
        raise HTTPException(503, "Relay ueberlastet, bitte spaeter erneut") from exc
    # Dieselbe Ankuendigung wie in der WS-Challenge, siehe
    # ANMELDUNG_WS_PRAEFIX. Apps bis 2.0.0 lesen nur `nonce`.
    namen = relay_namen()
    return {"nonce": b64e(nonce), **({"relay": list(namen)} if namen else {})}


def oeffentlicher_schluessel_ok(roh: bytes) -> bool:
    """Ist das ein Curve25519-Schluessel in einer der beiden ueblichen Formen?

    libsignal serialisiert oeffentliche Schluessel MIT dem Typ-Byte 0x05, also
    33 Byte — so schickt die App signed_prekey und die Einmalschluessel
    (app/lib/core/net/relay_protocol.dart, Kopfkommentar). 32 rohe Bytes
    bleiben erlaubt, weil sie in den Tests und bei eigenen Clients vorkommen
    und fuer den Server ohnehin undurchsichtig sind.

    WARUM UEBERHAUPT GEPRUEFT: der Server reicht diese Bloecke nur durch, aber
    er SPEICHERT sie. Ohne Laengenpruefung trug jedes Feld, was nginx
    durchliess (256 KiB Rumpf), und jede Registrierung konnte rund 190 KiB
    belegen — dauerhaft, purge_expired ruehrt identities nicht an (Audit vom
    25.09.2026).
    """
    return len(roh) == 32 or (len(roh) == 33 and roh[0] == 0x05)


# Laenge einer XEdDSA-/Ed25519-Signatur.
SIGNATUR_LAENGE = 64


class KyberTeil(NamedTuple):
    """Der dekodierte Kyber-Teil eines Buendels, fertig zum Speichern."""
    kennung: int
    schluessel: bytes                     # 1569 Byte, beginnt mit 0x08
    signatur: bytes                       # 64 Byte
    einmal: list[tuple[int, bytes, bytes]]  # (key_id, Schluessel, Signatur)


def kyber_schluessel_ok(roh: bytes) -> bool:
    """1569 Byte mit Typbyte 0x08 — die serialisierte Form aus libsignal.

    ANDERS ALS oeffentlicher_schluessel_ok() OHNE eine rohe Ersatzform. Dort
    sind 32 rohe Bytes erlaubt, weil alte Tests und eigene Clients sie
    schicken; fuer Kyber gibt es keinen solchen Bestand, und libsignal liest
    einen Kyber-Schluessel nur mit Typbyte wieder ein. Ein Block ohne waere
    fuer jeden Abrufer unbrauchbar und belegte trotzdem 2 KB Platte.
    """
    return len(roh) == KYBER_SCHLUESSEL_LAENGE and roh[0] == KYBER_TYPBYTE


def kyber_aus_buendel(bundle: PreKeyBundle) -> KyberTeil | None:
    """Prueft die FORM des Kyber-Teils und dekodiert ihn. None: kein Kyber.

    Alles hier ist billig (Laengen, Typbyte, Kennungen) und laeuft deshalb wie
    die EC-Laengen VOR dem Nonce und dem Besitznachweis: ein kaputtes Buendel
    kostet weder einen Nonce-Platz noch eine einzige XEdDSA-Pruefung. Die
    Signaturen prueft pruefe_kyber_signaturen() erst danach.

    Wirft HTTPException(400) bei allem, was nicht passt — und zwar IMMER, auch
    solange kyber_pflicht() aus ist. Optional heisst "darf fehlen", nicht
    "darf kaputt sein": ein halber Kyber-Teil, still verworfen, liesse das
    Geraet ohne Kyber dastehen, und die App merkte es erst daran, dass
    niemand mit neuer App ihr mehr schreiben kann.
    """
    last_resort = (bundle.kyber_prekey_id, bundle.kyber_prekey,
                   bundle.kyber_prekey_sig)
    if all(f is None for f in last_resort):
        if bundle.one_time_kyber_prekeys:
            # Einmalschluessel ohne Last-Resort: libsignal kann daraus kein
            # Buendel bauen, sobald der Vorrat leer ist — und
            # canonical_bytes() nimmt den Vorrat nur MIT kyber_prekey auf,
            # er stuende also ungeschuetzt im Rumpf.
            raise HTTPException(400, "one_time_kyber_prekeys ohne kyber_prekey")
        return None
    if any(f is None for f in last_resort):
        raise HTTPException(400, "kyber_prekey, kyber_prekey_id und "
                                 "kyber_prekey_sig gehoeren zusammen")
    if bundle.device_id is not None and bundle.device_id > LIBSIGNAL_GERAET_MAX:
        raise HTTPException(400, f"device_id muss mit Kyber hoechstens "
                                 f"{LIBSIGNAL_GERAET_MAX} sein (libsignal)")

    try:
        schluessel = b64d(bundle.kyber_prekey)
        signatur = b64d(bundle.kyber_prekey_sig)
        einmal = [(k.key_id, b64d(k.public_key), b64d(k.signature))
                  for k in bundle.one_time_kyber_prekeys]
    except ValueError as exc:
        raise HTTPException(400, "Bundle enthaelt ungueltiges base64") from exc

    if not kyber_schluessel_ok(schluessel):
        raise HTTPException(400, "kyber_prekey muss 1569 Byte (0x08 + 1568) sein")
    if len(signatur) != SIGNATUR_LAENGE:
        raise HTTPException(400, "kyber_prekey_sig muss 64 Byte sein")
    if not all(kyber_schluessel_ok(s) for _, s, _ in einmal):
        raise HTTPException(400, "one_time_kyber_prekeys: Schluessel muss "
                                 "1569 Byte (0x08 + 1568) sein")
    if not all(len(sig) == SIGNATUR_LAENGE for _, _, sig in einmal):
        raise HTTPException(400, "one_time_kyber_prekeys: Signatur muss 64 Byte sein")

    # DOPPELTE KENNUNGEN VOR DEN SIGNATUREN. Beim EC-Vorrat faengt das erst
    # der Primaerschluessel beim INSERT (IntegrityError -> 400); hier kaeme
    # der Fehler damit erst nach 51 Signaturpruefungen.
    kennungen = [kid for kid, _, _ in einmal]
    if len(set(kennungen)) != len(kennungen):
        raise HTTPException(400, "one_time_kyber_prekeys: key_id doppelt")
    # Und der Last-Resort-Schluessel darf keine Kennung mit einem
    # Einmalschluessel teilen. In libsignal liegen beide Sorten im SELBEN
    # Kyber-Speicher unter ihrer Kennung; teilen sie sich eine, verbraucht die
    # App mit dem Einmalschluessel auch den Last-Resort-Schluessel, und jede
    # spaetere Sitzung ueber den Last-Resort scheitert beim Empfaenger mit
    # "unbekannter Kyber-Prekey". Das ist ein Fehler der App, und er soll beim
    # Anmelden auffallen, nicht Wochen spaeter beim Kontakt.
    if bundle.kyber_prekey_id in kennungen:
        raise HTTPException(400, "kyber_prekey_id steht auch unter den "
                                 "one_time_kyber_prekeys")
    return KyberTeil(bundle.kyber_prekey_id, schluessel, signatur, einmal)


def pruefe_kyber_signaturen(identity_key: bytes, kyber: KyberTeil) -> None:
    """Jede Kyber-Signatur gegen den Identitaetsschluessel. 400 beim ersten Fehler.

    Mit derselben verify_signature wie der Besitznachweis — also mit beiden
    Vorzeichenbits, die libsignal in Signaturen legt (siehe dort). Signiert
    sind die vollen 1569 Byte MIT Typbyte, siehe KYBER_SCHLUESSEL_LAENGE.

    ERST NACH DEM BESITZNACHWEIS gerufen. Bis zu 51 Pruefungen kosten 5 ms
    (KYBER_OTK_MAX_JE_BUENDEL); die soll nur bezahlen muessen, wer den
    privaten Identitaetsschluessel hat. Ein Fremder mit einem Buendel unter
    fremder Adresse scheitert vorher mit 403 und hat dem Relay nicht mehr
    Arbeit gemacht als ohne Kyber.

    WARUM DER RELAY UEBERHAUPT PRUEFT, obwohl die App des Absenders es beim
    Sitzungsaufbau ohnehin tut: ein Schluessel mit falscher Signatur ist fuer
    JEDEN Abrufer wertlos (`invalidSignature` in libsignal). Gespeichert
    belegte er Platz, und ausgegeben verbrauchte er beim Abrufer einen
    Versuch und beim Opfer einen Einmalschluessel — fuer nichts. Den
    signierten EC-Prekey prueft der Relay dagegen bis heute nur auf seine
    Laenge; die Testhelfer schicken dort Zufallsbytes, und eine
    nachtraegliche Pruefung gehoert in einen eigenen Schritt.
    """
    if not verify_signature(identity_key, kyber.schluessel, kyber.signatur):
        raise HTTPException(400, "kyber_prekey_sig passt nicht zum identity_key")
    for kid, schluessel, signatur in kyber.einmal:
        if not verify_signature(identity_key, schluessel, signatur):
            raise HTTPException(
                400, f"one_time_kyber_prekeys: Signatur von key_id {kid} "
                     f"passt nicht zum identity_key")


@app.post("/register")
def register(req: RegisterRequest, request: Request):
    """Schritt 2: Bundle hochladen, signiert mit dem Identitaetsschluessel.

    Ohne diesen Nachweis konnte frueher jeder, der eine oeffentliche Adresse
    kannte, das fremde Bundle ueberschreiben — Sessions brachen, der
    Prekey-Pool war weg.
    """
    if not herkunft_ok(request, "reg", cost=5):
        raise HTTPException(429, "zu viele Anfragen")

    bundle = req.bundle
    try:
        identity_key = b64d(bundle.identity_key)
    except Exception as exc:
        raise HTTPException(400, "identity_key ist kein gueltiges base64") from exc

    if len(identity_key) != 32:
        raise HTTPException(400, "identity_key muss 32 Byte sein")
    if encode_id(identity_key) != bundle.user_id:
        raise HTTPException(400, "user_id passt nicht zum identity_key")

    # ALLE Laengen VOR dem Nonce und vor der Signaturpruefung — ein zu grosses
    # Buendel kostet dann weder einen Nonce-Platz noch acht XEdDSA-Pruefungen.
    # Die Anzahl der Einmalschluessel begrenzt schon das Modell
    # (OTK_MAX_JE_BUENDEL, 422 vor diesem Code).
    try:
        signed_prekey = b64d(bundle.signed_prekey)
        signed_prekey_sig = b64d(bundle.signed_prekey_sig)
        otk_roh = [(k.key_id, b64d(k.public_key)) for k in bundle.one_time_prekeys]
    except ValueError as exc:
        raise HTTPException(400, "Bundle enthaelt ungueltiges base64") from exc
    if not oeffentlicher_schluessel_ok(signed_prekey):
        raise HTTPException(400, "signed_prekey muss 33 Byte (0x05 + 32) sein")
    if len(signed_prekey_sig) != SIGNATUR_LAENGE:
        raise HTTPException(400, "signed_prekey_sig muss 64 Byte sein")
    if not all(oeffentlicher_schluessel_ok(roh) for _, roh in otk_roh):
        raise HTTPException(400, "one_time_prekeys: Schluessel muss 33 Byte "
                                 "(0x05 + 32) sein")

    # Der Kyber-Teil, ebenfalls nur seine Form — die Signaturen erst nach dem
    # Besitznachweis (pruefe_kyber_signaturen). None heisst: keiner da.
    kyber = kyber_aus_buendel(bundle)
    if kyber is None and kyber_pflicht():
        # 400 und nicht 426 "Upgrade Required": die Apps bis 1.9 werten nur
        # aus, ob die Anmeldung durchging, und zeigen den Text. Den
        # Update-Hinweis bekommen sie ohnehin schon ueber auth_result
        # (NEUESTE_FASSUNG) — vorausgesetzt, sie waren schon angemeldet.
        raise HTTPException(400, "Dieser Relay verlangt Kyber-Prekeys (PQXDH) "
                                 "— bitte BitDM aktualisieren")

    try:
        signature = b64d(req.signature)
    except Exception as exc:
        raise HTTPException(400, "signature ist kein gueltiges base64") from exc

    # Alte oder neue Form (KR-2, siehe ANMELDUNG_WS_PRAEFIX). VOR den Nonces:
    # ein fremder Relay-Name kostet dann weder Pruefungen noch ein Nonce.
    zulaessig, host = angemeldeter_relay(req.relay)
    if not zulaessig:
        raise HTTPException(403, "Besitznachweis ohne passenden Relay-Namen")

    def besitz_nachricht(n: bytes) -> bytes:
        """Die Bytes, die der Identitaetsschluessel (und mit Liste der
        Geraeteschluessel hinter ANMELDE_PRAEFIX) signiert hat."""
        if host is not None:
            return registrier_nachricht(host, n, inhalt)
        return n + inhalt

    # Das Nonce haengt am (Adresse, Geraet)-Paar. Ein Geraet kann sich damit
    # nicht mit dem Nonce eines anderen anmelden, und zwei Geraete derselben
    # Adresse nehmen sich ihre Nonces nicht mehr gegenseitig weg.
    #
    # Der Client schickt sein Nonce nicht mit (so ist er ausgeliefert, 1.6 bis
    # 1.8). Also wird die Signatur gegen JEDES offene Nonce des Paares
    # geprueft, und verbraucht wird nur das, zu dem sie passt — siehe
    # verbrauche_nonce, warum erst danach.
    kandidaten = offene_nonces(bundle.user_id, bundle.device_id,
                               nonce_herkunft(request))
    if not kandidaten:
        raise HTTPException(401, "kein gueltiges Nonce — erst /register/challenge")

    inhalt = hashlib.sha256(bundle.canonical_bytes()).digest()
    treffer = next((n for n in kandidaten
                    if verify_signature(identity_key, besitz_nachricht(n),
                                        signature)), None)
    if treffer is None:
        raise HTTPException(403, "Besitznachweis fehlgeschlagen")
    if not verbrauche_nonce(bundle.user_id, bundle.device_id, treffer):
        # Zwischen Pruefen und Verbrauchen hat ein gleichzeitiger Aufruf mit
        # derselben Signatur das Nonce genommen (oder es ist gerade
        # abgelaufen). Genau einmal heisst genau einmal.
        raise HTTPException(401, "kein gueltiges Nonce — erst /register/challenge")

    # Jetzt, mit nachgewiesenem Besitz, die Kyber-Signaturen. Scheitert eine,
    # ist das Nonce schon verbraucht; der Client holt fuer den naechsten
    # Versuch ein neues, wie nach jeder anderen Absage auch.
    if kyber is not None:
        pruefe_kyber_signaturen(identity_key, kyber)

    # Die Sperre liegt eine Ebene ueber `with db:` und bleibt bis hinter den
    # COUNT offen. Sonst zaehlte die Antwort einen Stand, den inzwischen ein
    # anderer Aufrufer veraendert haben kann — und der Client leitet aus dieser
    # Zahl ab, ob er Prekeys nachliefern muss.
    # Fehlt die Kennung, ist es Geraet 1 — die Regel fuer den ganzen Umbau.
    geraet = 1 if bundle.device_id is None else bundle.device_id
    # Nur mit Liste und nur geprueft gesetzt, siehe unten. Ohne Liste gibt es
    # keinen Schluessel, gegen den sie gelten koennte.
    spk_sig_speichern: bytes | None = None
    # Ob diese Anfrage eine Marke fuer eine neue Adresse genommen hat, die
    # zurueckgeht, falls das Buendel sich doch nicht speichern laesst.
    marke_genommen = False
    angelegt = False

    with schreibsperre:
        # DIE GERAETELISTE (GERAETEABMELDUNG.md §8.4), und zwar INNERHALB der
        # Sperre: setze_geraeteliste loescht unter derselben Sperre die Zeile
        # eines abgemeldeten Geraets. Stuende die Pruefung davor, koennte eine
        # Abmeldung zwischen Pruefen und Einfuegen fallen — und die
        # Registrierung legte die Zeile des gerade abgemeldeten Geraets wieder
        # an.
        #
        # Ohne Liste bleibt alles wie bisher; die App legt sie vor der ersten
        # Anmeldung an.
        liste = gespeicherte_liste(bundle.user_id)
        if liste is not None:
            schluessel = liste[1].get(geraet)
            if schluessel is None:
                raise HTTPException(403, "Geraet nicht in der Geraeteliste")
            # Der Identitaetsschluessel allein reicht nicht mehr: den haben
            # alle Geraete der Adresse, auch ein abgemeldetes. Ueber dieselben
            # Bytes wie der Besitznachweis, also an dieses Nonce und dieses
            # Buendel gebunden.
            if not geraete_signatur_ok(schluessel, besitz_nachricht(treffer),
                                       req.geraete_signatur):
                raise HTTPException(403, "Geraeteschluessel fehlt oder passt nicht")
            # DER SIGNIERTE PREKEY, AN DEN GERAETESCHLUESSEL GEBUNDEN
            # (§12.5 a). Fehlt die Signatur, geht es weiter (App vor 2.0.1);
            # eine FALSCHE wird nie gespeichert — sonst lieferte /prekey ein
            # Buendel aus, an dem jeder Kontakt scheitert.
            if req.spk_geraete_sig is not None:
                try:
                    spk_sig = b64d(req.spk_geraete_sig)
                except ValueError as exc:
                    raise HTTPException(400, "spk_geraete_sig ist kein "
                                             "gueltiges base64") from exc
                if not verify_signature(
                        schluessel,
                        spk_nachricht(bundle.user_id, geraet,
                                      bundle.signed_prekey_id,
                                      b64e(signed_prekey)),
                        spk_sig):
                    raise HTTPException(403, "spk_geraete_sig passt nicht")
                spk_sig_speichern = spk_sig

        # DAS DACH, und zwar nur fuer NEUE Adressen.
        #
        # Innerhalb der Sperre, sonst kaeme zwischen Zaehlen und Einfuegen ein
        # anderer Aufrufer durch — bei einer Flut ist das kein theoretischer
        # Fall, sondern der Normalfall.
        #
        # Wer schon eingetragen ist, kommt IMMER durch: sein Bundle zu
        # erneuern belegt keinen neuen Platz, und ein volles Relay waere sonst
        # ausgerechnet fuer seine eigenen Nutzer unbenutzbar — die koennten
        # keine Prekeys mehr nachliefern und waeren nach dem Aufbrauchen des
        # Vorrats nicht mehr erreichbar.
        schon_da = db.execute(
            "SELECT 1 FROM identities WHERE user_id=? AND device_id=?",
            (bundle.user_id, geraet),
        ).fetchone() is not None
        # ZWEI VERSCHIEDENE DECKEL, und sie duerfen nicht verwechselt werden.
        geraete_dieser_adresse = db.execute(
            "SELECT COUNT(*) FROM identities WHERE user_id=?", (bundle.user_id,)
        ).fetchone()[0]

        if not schon_da and geraete_dieser_adresse == 0:
            # Neue ADRESSE. COUNT(DISTINCT user_id) und nicht COUNT(*): sonst
            # saenke die Aufnahmegrenze des Relays um den Geraetefaktor, und
            # IDENTITAETEN_MAX bedeutete etwas anderes als vor dem Umbau.
            wie_viele = db.execute(
                "SELECT COUNT(DISTINCT user_id) FROM identities").fetchone()[0]
            if wie_viele >= IDENTITAETEN_MAX:
                # 507, nicht 429: das ist keine Bremse, die nach einer Weile
                # nachgibt, sondern eine volle Ablage. Der Unterschied gehoert
                # in die Antwort, sonst versucht es der Client fuer immer.
                _melde_das_dach(wie_viele)
                raise HTTPException(507, "Dieser Relay nimmt keine neuen "
                                         "Adressen mehr auf")
            # DIE MARKE FUER EINE NEUE ADRESSE (SV-3, NEUE_ADRESSEN_JE_TAG)
            # erst hier, als letzte Pruefung vor dem INSERT. Jede Absage
            # davor - Besitznachweis, Kyber, Geraeteliste, Adressdach -
            # kostet die Herkunft nichts; sonst hielte ein dauerhaft
            # scheiternder Client hinter einer geteilten IP den Eimer fuer
            # alle dort leer.
            #
            # Unter schreibsperre, in der auch jeder INSERT in `identities`
            # liegt: "Adresse noch unbekannt" und "Marke genommen" sind damit
            # ein Schritt. Zwei gleichzeitige erste Registrierungen derselben
            # Adresse zahlen einmal (die zweite sieht die Zeile der ersten),
            # und mehr Adressen als Marken kommen auch parallel nicht durch -
            # _take selbst haelt _speichersperre. Kein await dazwischen: der
            # Endpunkt ist synchron und laeuft im Threadpool.
            if not neue_adresse_ok(request):
                raise HTTPException(429, "zu viele neue Adressen von hier, "
                                         "bitte spaeter erneut")
            marke_genommen = True
            if wie_viele + 1 >= DACH_WARNUNG_AB * IDENTITAETEN_MAX:
                _melde_das_dach(wie_viele + 1)

        if not schon_da and geraete_dieser_adresse >= GERAETE_MAX:
            # Neues GERAET einer bekannten Adresse, und die ist voll.
            #
            # Erst nach Platz suchen: ein Geraet ohne Lebenszeichen seit
            # GERAET_TTL ist ein vergessenes Telefon und darf dem neuen
            # weichen. Genommen wird das aelteste davon.
            totes = db.execute(
                f"SELECT device_id FROM identities WHERE user_id=?"
                f" AND {LEBENSZEICHEN} < ? ORDER BY {LEBENSZEICHEN}, device_id"
                f" LIMIT 1",
                (bundle.user_id, time.time() - GERAET_TTL),
            ).fetchone()
            if totes is None:
                # KEIN VERDRAENGEN LEBENDER GERAETE. Bei sechs lebenden
                # Geraeten wuerfen sie sich bei jeder Buendel-Erneuerung
                # gegenseitig hinaus (die App erneuert auf `prekeys_low`), und
                # aus dem Dauerpendeln wuerde Nachrichtenverlust. Eine
                # ehrliche Absage ist besser.
                raise HTTPException(
                    507, f"Diese Adresse hat schon {GERAETE_MAX} Geraete")
            with db:
                weg, kyber_weg = loesche_geraet(bundle.user_id, totes[0])
            kyber_zeilen_aendern(-kyber_weg)
            queue_zeilen_aendern(-weg)

        # Der Last-Resort-Teil fuer die Zeile in `identities`. Ohne Kyber
        # werden die drei Spalten auf NULL GESETZT und nicht stehen gelassen:
        # meldet sich ein Geraet ohne Kyber an (alte App, etwa nach einem
        # Zurueckspielen), passen die alten Kyber-Schluessel nicht mehr zu dem,
        # was auf dem Geraet laeuft. /prekey gaebe sonst ein Buendel aus, mit
        # dem neue Apps eine PQXDH-Sitzung bauen, die das Geraet gar nicht
        # entschluesseln kann. Ohne Felder bauen sie keine — und sehen, warum.
        kyber_spalten = ((kyber.kennung, kyber.schluessel, kyber.signatur)
                         if kyber is not None else (None, None, None))
        kyber_neu = sorted(kyber.einmal) if kyber is not None else []
        kyber_alt = 0
        try:
            with db:
                db.execute(
                    "INSERT INTO identities (user_id, device_id, identity_key,"
                    " registration_id, signed_prekey_id, signed_prekey,"
                    " signed_prekey_sig, updated_at, kyber_prekey_id,"
                    " kyber_prekey, kyber_prekey_sig, spk_geraete_sig)"
                    " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)"
                    " ON CONFLICT(user_id, device_id) DO UPDATE SET"
                    " identity_key=excluded.identity_key,"
                    " registration_id=excluded.registration_id,"
                    " signed_prekey_id=excluded.signed_prekey_id,"
                    " signed_prekey=excluded.signed_prekey,"
                    " signed_prekey_sig=excluded.signed_prekey_sig,"
                    " updated_at=excluded.updated_at,"
                    " kyber_prekey_id=excluded.kyber_prekey_id,"
                    " kyber_prekey=excluded.kyber_prekey,"
                    " kyber_prekey_sig=excluded.kyber_prekey_sig,"
                    # IMMER UEBERSCHRIEBEN, auch mit NULL: die alte Signatur
                    # gehoert zum alten Prekey und passte zum neuen nicht.
                    " spk_geraete_sig=excluded.spk_geraete_sig",
                    (bundle.user_id, geraet, identity_key, bundle.registration_id,
                     bundle.signed_prekey_id, signed_prekey,
                     signed_prekey_sig, time.time(), *kyber_spalten,
                     spk_sig_speichern),
                )
                # NUR die Einmalschluessel DIESES Geraets. Ohne das
                # `AND device_id=?` raeumte jede Nachlieferung eines Geraets den
                # Vorrat aller anderen derselben Adresse weg — genau das
                # geschah bis zum 30.07.2026 zwischen zwei Geraeten mit
                # denselben zwoelf Woertern, und keines merkte etwas davon.
                db.execute("DELETE FROM one_time_prekeys"
                           " WHERE user_id=? AND device_id=?",
                           (bundle.user_id, geraet))
                db.executemany(
                    "INSERT INTO one_time_prekeys (user_id, device_id, key_id,"
                    " public_key) VALUES (?,?,?,?)",
                    [(bundle.user_id, geraet, key_id, roh)
                     for key_id, roh in otk_roh],
                )
                # Der Kyber-Einmalvorrat wird genauso VOLLSTAENDIG ersetzt,
                # nur dieses Geraet, auch dann, wenn das Buendel keinen
                # mitbringt: die alten Schluessel gehoeren zu einem Stand der
                # App, den diese Anmeldung gerade abloest.
                kyber_alt = db.execute(
                    "DELETE FROM one_time_kyber_prekeys"
                    " WHERE user_id=? AND device_id=?",
                    (bundle.user_id, geraet)).rowcount
                # DAS DACH (KYBER_OTK_MAX_GESAMT). Platz ist, was die anderen
                # Geraete uebrig lassen — der eigene alte Vorrat ist gerade
                # weg und zaehlt nicht mehr. Am Dach wird GEKUERZT, nicht
                # abgewiesen (Begruendung dort); genommen werden die
                # kleinsten Kennungen, damit dasselbe Buendel immer dieselben
                # Schluessel ergibt. Was die App davon hat, sagt ihr die Zahl
                # in der Antwort.
                platz = max(0, KYBER_OTK_MAX_GESAMT - (_kyber_zeilen - kyber_alt))
                kyber_neu = kyber_neu[:platz]
                db.executemany(
                    "INSERT INTO one_time_kyber_prekeys (user_id, device_id,"
                    " key_id, public_key, signature) VALUES (?,?,?,?,?)",
                    [(bundle.user_id, geraet, kid, schluessel, signatur)
                     for kid, schluessel, signatur in kyber_neu],
                )
            angelegt = True
        except (sqlite3.Error, ValueError, OverflowError) as exc:
            # OverflowError gehoert dazu, seit die Kennungen im Rumpf keine
            # Obergrenze haben: registration_id, signed_prekey_id und key_id
            # sind blanke `int`, und alles ab 2**63 wirft beim Binden. Ohne
            # diesen Eintrag kaeme dafuer 500 statt 400 — ein Fehler des
            # Absenders, den der Server als eigenen meldet. GEBUNDEN wird hier
            # nicht: jede Schranke wiese Werte ab, die heute sauber
            # durchgehen (das Fixture "grosse Zahlen" faehrt
            # signed_prekey_id=16777215 und registration_id=0).
            #
            # OHNE den Text der Ausnahme in der Antwort. Frueher stand er drin
            # ("UNIQUE constraint failed: one_time_prekeys.user_id, ..."), und
            # das ist Auskunft ueber Schema und Datenbank an jeden, der ein
            # kaputtes Buendel schickt. Der Client kann damit nichts anfangen;
            # wer nachsehen muss, hat das Journal.
            print(f"[!] /register: Bundle nicht gespeichert ({type(exc).__name__})")
            raise HTTPException(400, "Bundle konnte nicht gespeichert werden") from exc
        finally:
            # Zurueckgerollt heisst: keine neue Adresse, also auch keine
            # Marke (SV-3). Noch unter schreibsperre, damit kein anderer
            # Aufruf dazwischen den leeren Eimer sieht und abgewiesen wird.
            if marke_genommen and not angelegt:
                neue_adresse_zurueck(request)
        # Nach dem Commit, noch unter der Sperre — siehe _kyber_zeilen.
        kyber_zeilen_aendern(len(kyber_neu) - kyber_alt)

        # Zaehlt JE GERAET. Der Client leitet aus dieser Zahl ab, ob er
        # nachliefern muss — adressweit gezaehlt saehe ein leeres Zweitgeraet
        # den vollen Vorrat des Erstgeraets und lieferte nie nach.
        count = db.execute(
            "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=? AND device_id=?",
            (bundle.user_id, geraet),
        ).fetchone()[0]
        kyber_count = db.execute(
            "SELECT COUNT(*) FROM one_time_kyber_prekeys"
            " WHERE user_id=? AND device_id=?",
            (bundle.user_id, geraet),
        ).fetchone()[0]
    # `one_time_kyber_prekeys` steht genau dann da, wenn die Anmeldung Kyber
    # trug — dann auch bei 0. Ohne Kyber bleibt die Antwort Zeichen fuer
    # Zeichen die alte (MEHRGERAETE.md §3.2 "Antwort unveraendert"; die Tests
    # vergleichen sie als Ganzes). Eine neue App erkennt am Fehlen des Feldes
    # einen Relay, der Kyber nicht kennt — der wuerde die Felder still
    # verwerfen (pydantic ignoriert Unbekanntes), und die App stuende ohne
    # Kyber da, ohne es zu merken. (Praktisch scheitert sie dort schon am
    # Besitznachweis, weil der alte Relay die Kyber-Felder nicht mitsigniert
    # erwartet — aber darauf soll sich niemand verlassen muessen.) Und am
    # Dach sieht sie hier, wie viel ihres Vorrats angekommen ist.
    antwort = {"ok": True, "one_time_prekeys": count}
    if kyber is not None:
        antwort["one_time_kyber_prekeys"] = kyber_count
    return antwort


# ------------------------------------------------------------- Prekeys abholen

@app.get("/prekey/{user_id}")
def get_prekey(user_id: str, request: Request, nur_geraete: bool = False):
    """Buendel fuer den X3DH-Aufbau — EINES JE GERAET dieser Adresse.

    Ratenbegrenzt: sonst leert eine Schleife den Pool eines beliebigen Nutzers
    und zwingt alle kuenftigen Kontakte auf den schwaecheren X3DH-Pfad ohne
    One-Time-Prekey.

    DIE FLACHEN FELDER BLEIBEN und sind eine Kopie von `geraete[0]`, also des
    Geraets mit der KLEINSTEN Kennung — nicht fest "Geraet 1". Ist Geraet 1
    weggeraeumt (raeume_vergessene_geraete), muss ein Client, der nichts von
    Geraeten weiss, trotzdem noch jemanden erreichen. Der Einmalschluessel im
    flachen Block ist DERSELBE wie in geraete[0] und kein zweiter, sonst
    kostete jede Abfrage einen Schluessel zu viel.

    `?nur_geraete=1` gibt nur die Kennungen zurueck: keine Schluessel, kein
    Einmalschluessel wird gezogen, kein Eimer-Token bei otk_limit_ok. Das ist
    der Aufruf, den der Client oft macht (Auffrischung der Geraeteliste), und
    er darf deshalb nichts verbrauchen.

    KYBER (seit 16.10.2026): je Geraet, das sich mit Kyber angemeldet hat,
    stehen `kyber_prekey_id`, `kyber_prekey`, `kyber_prekey_sig` und
    `kyber_einmal` im Eintrag — und als Kopie von geraete[0] auch flach,
    dieselbe Regel wie oben. Ein Einmalschluessel, wenn einer da ist und die
    Bremse es zulaesst (`kyber_einmal: true`), sonst der Last-Resort-Schluessel
    (`false`). Bei einem Geraet ohne Kyber fehlen ALLE VIER Felder, und zwar
    ganz und nicht als null: eine neue App erkennt daran ein Geraet, mit dem
    sie keine Sitzung bauen kann, und eine alte liest ohnehin nur, was sie
    kennt.
    """
    if not herkunft_ok(request, "pk"):
        raise HTTPException(429, "zu viele Anfragen")

    # Der SELECT gehoert in dieselbe Sperre wie das DELETE darunter, damit das
    # ausgelieferte Bundle aus EINEM Zustand stammt: davor konnte er die noch
    # nicht committete Identitaet eines anderen Threads sehen.
    with schreibsperre:
        rows = db.execute(
            "SELECT device_id, identity_key, signed_prekey_id, signed_prekey,"
            " signed_prekey_sig, registration_id, kyber_prekey_id, kyber_prekey,"
            " kyber_prekey_sig, spk_geraete_sig FROM identities"
            " WHERE user_id=? ORDER BY device_id", (user_id,)
        ).fetchall()
        # NUR GERAETE DER LISTE. Eine Zeile ausserhalb gibt es nur fuer einen
        # Augenblick (setze_geraeteliste loescht sie unter derselben Sperre)
        # — aber ein Buendel, das in diesem Augenblick hinausginge, liesse
        # einen Absender an ein gerade abgemeldetes Geraet verschluesseln.
        liste = gespeicherte_liste(user_id)
        if liste is not None:
            rows = [r for r in rows if r[0] in liste[1]]
        # Mit Liste, aber ohne angemeldetes Geraet (gleich nach dem
        # Zuruecksetzen, bevor sich das neue Geraet anmeldet): `?nur_geraete=1`
        # antwortet trotzdem, mit leerer Geraeteliste und der signierten Liste.
        # Ein 404 hiesse fuer die App "diese Adresse hat noch nichts" — und
        # ein neues Geraet waehlte seine Kennung, ohne die belegten zu kennen.
        if not rows and not (nur_geraete and liste is not None):
            raise HTTPException(404, "unbekannte Adresse")
        # Die signierte Liste geht mit, damit jeder Abrufer selbst pruefen
        # kann, welche Geraete die Adresse wirklich hat (§8.6, Stufe 2) —
        # und zwar mit dem Abruf, den er ohnehin macht.
        liste_json = geraeteliste_als_json(user_id)

        if nur_geraete:
            antwort = {
                "user_id": user_id,
                "geraete": [{"device_id": r[0], "registration_id": r[5]}
                            for r in rows],
            }
            if liste_json is not None:
                antwort["geraeteliste"] = liste_json
            return antwort

        # One-Time-Prekey nur ausgeben, wenn das Limit dieser Adresse es zulaesst.
        # Bei Ueberschreitung kommt das Bundle OHNE — X3DH funktioniert auch dann,
        # nur etwas schwaecher. Das ist bewusst besser als ein 429: legitime
        # Kontakte koennen weiterhin eine Sitzung aufbauen, waehrend der
        # Drain-Angriff ins Leere laeuft.
        #
        # EINMAL JE ANFRAGE gebucht, nicht je ausgegebenem Schluessel: greift
        # die Bremse, kommen ALLE Geraete ohne Einmalschluessel. Der Preis ist,
        # dass der Prekey-Drain um den Geraetefaktor billiger wird (bei 5
        # Geraeten 5x). Tragbar, weil ein geleerter Vorrat laut Entwurf kein
        # Fehler ist, sondern X3DH ohne Einmalschluessel.
        #
        # DIESELBE BUCHUNG GILT FUER DEN KYBER-EINMALSCHLUESSEL, kein eigener
        # Eimer. Ein Sitzungsaufbau verbraucht je Geraet genau einen EC- und
        # einen Kyber-Einmalschluessel (PQXDH nimmt beide); ein zweiter Eimer
        # liesse einen ehrlichen Abrufer doppelt zahlen, ohne den Drain
        # langsamer zu machen — der Angreifer zoege dann eben aus beiden. Der
        # Drain ist damit fuer beide Sorten gleich teuer (OTK_REFILL_PER_SEC,
        # 6 je Minute und Adresse): 50 Kyber-Einmalschluessel sind nach rund
        # 7 Minuten weg, 100 EC-Schluessel nach rund 15. Was danach kommt, ist
        # der Last-Resort-Schluessel — PQXDH laeuft weiter, nur ohne die
        # Einmal-Eigenschaft fuer den Kyber-Teil. Und die Platte beruehrt der
        # Drain nicht: er macht die Tabelle kleiner, nicht groesser.
        otks: dict[int, tuple] = {}
        kybers: dict[int, tuple] = {}
        if otk_limit_ok(user_id):
            # Atomar ist hier nur die ANWEISUNG: DELETE ... RETURNING gibt die
            # Zeile heraus, die es selbst entfernt hat, dieselbe kann also nie
            # zweimal herausfallen. Die Transaktion darum ist eine zweite
            # Sache — sie liegt auf der geteilten Verbindung, und ohne
            # schreibsperre konnte der Rollback eines fremden Threads dieses
            # DELETE mit zuruecknehmen, waehrend der Prekey unten schon im
            # JSON stand.
            with db:
                for r in rows:
                    treffer = db.execute(
                        "DELETE FROM one_time_prekeys WHERE rowid = ("
                        "  SELECT rowid FROM one_time_prekeys"
                        "  WHERE user_id=? AND device_id=? LIMIT 1"
                        ") RETURNING key_id, public_key", (user_id, r[0])
                    ).fetchone()
                    if treffer is not None:
                        otks[r[0]] = treffer
                    # Nur fuer Geraete MIT Last-Resort-Schluessel. register()
                    # laesst ohnehin keinen Kyber-Vorrat ohne ihn zu; die
                    # Bedingung haelt nur fest, dass ein Einmalschluessel
                    # allein nie ausgegeben wird — der Abrufer koennte ihn
                    # nicht in ein vollstaendiges Buendel einsetzen.
                    if r[7] is None:
                        continue
                    k_treffer = db.execute(
                        "DELETE FROM one_time_kyber_prekeys WHERE rowid = ("
                        "  SELECT rowid FROM one_time_kyber_prekeys"
                        "  WHERE user_id=? AND device_id=? LIMIT 1"
                        ") RETURNING key_id, public_key, signature",
                        (user_id, r[0])
                    ).fetchone()
                    if k_treffer is not None:
                        kybers[r[0]] = k_treffer
            # Nach dem Commit, noch unter der Sperre — siehe _kyber_zeilen.
            kyber_zeilen_aendern(-len(kybers))

    def als_geraet(r) -> dict:
        otk = otks.get(r[0])
        eintrag = {
            "device_id": r[0],
            "registration_id": r[5],
            "signed_prekey_id": r[2],
            "signed_prekey": b64e(r[3]),
            "signed_prekey_sig": b64e(r[4]),
            "one_time_prekey": (
                {"key_id": otk[0], "public_key": b64e(otk[1])} if otk else None
            ),
        }
        if r[9] is not None:
            # §12.5 a: der Kontakt prueft sie gegen den Schluessel der Liste.
            # Fehlt sie, fehlt das Feld ganz (wie bei Kyber).
            eintrag["spk_geraete_sig"] = b64e(r[9])
        if r[7] is not None:
            # Einmal- ODER Last-Resort-Schluessel, in denselben drei Feldern.
            # libsignals PreKeyBundle hat nur EINEN Platz fuer einen
            # Kyber-Prekey, und welcher es ist, muss der Absender nicht
            # wissen — der Empfaenger erkennt es an der Kennung. kyber_einmal
            # ist Auskunft fuer die App (Diagnose, Tests), keine Bedingung.
            kid, schluessel, signatur = kybers.get(r[0], (r[6], r[7], r[8]))
            eintrag.update({
                "kyber_prekey_id": kid,
                "kyber_prekey": b64e(schluessel),
                "kyber_prekey_sig": b64e(signatur),
                "kyber_einmal": r[0] in kybers,
            })
        return eintrag

    geraete = [als_geraet(r) for r in rows]
    erstes = geraete[0]
    antwort = {
        "user_id": user_id,
        # Der Identitaetsschluessel gehoert der ADRESSE, nicht dem Geraet — er
        # steht deshalb nur einmal da und nicht in jedem Geraeteeintrag.
        "identity_key": b64e(rows[0][1]),
        "registration_id": erstes["registration_id"],
        "signed_prekey_id": erstes["signed_prekey_id"],
        "signed_prekey": erstes["signed_prekey"],
        "signed_prekey_sig": erstes["signed_prekey_sig"],
        "one_time_prekey": erstes["one_time_prekey"],
    }
    # Flach dieselben Kyber-Felder wie in geraete[0] — derselbe Schluessel,
    # kein zweiter gezogener, aus demselben Grund wie beim EC-Einmalschluessel.
    for feld in ("kyber_prekey_id", "kyber_prekey", "kyber_prekey_sig",
                 "kyber_einmal", "spk_geraete_sig"):
        if feld in erstes:
            antwort[feld] = erstes[feld]
    antwort["geraete"] = geraete
    if liste_json is not None:
        antwort["geraeteliste"] = liste_json
    return antwort


# ---------------------------------------------------------------- Geraeteliste

@app.get("/geraeteliste/{user_id}")
def hole_geraeteliste(user_id: str, request: Request):
    """Die signierte Geraeteliste einer Adresse — fuer jeden, ohne Anmeldung.

    Oeffentlich wie /prekey: Kontakte brauchen sie, um nur an echte Geraete
    zu verschluesseln. Was sie verraet, verraet /prekey?nur_geraete=1 schon
    (wie viele Geraete, welche Kennungen); Namen stehen nur verschluesselt
    darin.
    """
    if not herkunft_ok(request, "pk"):
        raise HTTPException(429, "zu viele Anfragen")
    antwort = geraeteliste_als_json(user_id)
    if antwort is None:
        raise HTTPException(404, "keine Geraeteliste")
    return antwort


async def _melde_an_geraete(user_id: str, geraete, rahmen: dict,
                            schliessen: int | None = None) -> None:
    """Schickt verbundenen Geraeten einen Rahmen, auf Wunsch mit Schluss.

    Fehler werden geschluckt: eine Leitung, die gerade stirbt, darf die
    Antwort an den Aufrufer nicht verhindern — die Aenderung ist ja schon
    gespeichert, und wer sie verpasst, sieht sie beim naechsten Verbinden.
    """
    for geraet in geraete:
        ws = connections.get(user_id, {}).get(geraet)
        if ws is None:
            continue
        try:
            await ws.send_json(rahmen)
            if schliessen is not None:
                await ws.close(code=schliessen)
        except Exception:
            pass


@app.post("/geraeteliste")
async def setze_geraeteliste(req: GeraetelisteRequest, request: Request):
    """Eine neue Fassung der Geraeteliste (GERAETEABMELDUNG.md §8.3).

    ASYNC, nicht im Threadpool wie /register: abgemeldete Geraete werden
    sofort getrennt, und ihre Leitungen leben auf dem Event-Loop. Die Arbeit
    unter der schreibsperre hat kein await (siehe dort); die beiden
    Signaturpruefungen sind C-Code und kosten Mikrosekunden.
    """
    # EINE EIGENE FAMILIE und nicht "reg": jedes neue Geraet legt seine Liste
    # einmal an, und in derselben Familie verdoppelte das die Kosten jeder
    # Erstanmeldung - bei vielen neuen Nutzern hinter einer Adresse (NAT, Tor)
    # griff die Bremse dann doppelt so frueh. Zwei Signaturpruefungen in C
    # sind billig; die Bremse hier haelt nur Fluten ab.
    if not herkunft_ok(request, "liste", cost=2):
        raise HTTPException(429, "zu viele Anfragen")
    neu = lies_liste(req.liste, req.sig_identitaet, req.sig_geraet)
    uid = neu.adresse
    nachricht = LISTE_PRAEFIX + neu.roh.encode("ascii")

    with schreibsperre:
        alt = gespeicherte_liste(uid)
        if alt is None:
            # ANLAGE: nur Fassung 1, nur mit sich allein. Mehr Geraete gleich
            # bei der Anlage ginge nur mit dem Identitaetsschluessel — genau
            # dem, den jedes Geraet hat. Weitere kommen ueber den Beitritt.
            if neu.epoche != 1:
                raise HTTPException(409, "Epoche passt nicht (aktuell 0)")
            if list(neu.geraete) != [neu.unterzeichner]:
                raise HTTPException(403, "Die erste Liste enthaelt nur das "
                                         "anlegende Geraet")
            pruefschluessel = neu.geraete[neu.unterzeichner]
        else:
            alt_epoche, alt_geraete = alt
            # GENAU +1. Zwei Geraete, die gleichzeitig aendern, bekommen so
            # nicht beide recht: der zweite sieht 409, holt die neue Fassung
            # und entscheidet neu. Ein Sprung nach vorn wuerde nichts
            # schuetzen, nur die Epoche verbrauchen.
            if neu.epoche != alt_epoche + 1:
                raise HTTPException(409, f"Epoche passt nicht (aktuell {alt_epoche})")
            bisher = alt_geraete.get(neu.unterzeichner)
            if bisher is not None and neu.geraete.get(neu.unterzeichner, bisher) == bisher:
                # Ein Mitglied aendert — auch, wenn es sich selbst abmeldet
                # (dann fehlt es in der neuen Fassung). Gegen seinen Schluessel
                # aus der ALTEN Fassung: der neue Eintrag ist ja gerade das,
                # was es setzt.
                pruefschluessel = bisher
            else:
                # ZURUECKSETZEN: wer nicht drinsteht, kommt nur allein hinein
                # und wirft dabei alle anderen hinaus. Das kann jeder mit den
                # Woertern — auch ein Dieb, der sie hat. Deshalb ist es laut:
                # jedes andere Geraet faellt sichtbar heraus und erfaehrt es.
                if list(neu.geraete) != [neu.unterzeichner]:
                    raise HTTPException(403, "Nur ein Geraet der Liste darf "
                                             "Geraete hinzufuegen")
                pruefschluessel = neu.geraete[neu.unterzeichner]
        if not verify_signature(pruefschluessel, nachricht, neu.sig_geraet):
            raise HTTPException(403, "sig_geraet passt nicht")

        # WER GEHT: jedes Geraet, das in der alten Fassung stand oder eine
        # Zeile hat und in der neuen fehlt — oder dort mit einem ANDEREN
        # Schluessel steht (dieselbe Kennung, anderes Geraet). Zeilen ohne
        # Liste gibt es bei der Anlage: Geraete, die sich angemeldet hatten,
        # bevor es Listen gab.
        zeilen = {r[0] for r in db.execute(
            "SELECT device_id FROM identities WHERE user_id=?", (uid,))}
        bisherige = alt[1] if alt is not None else {}
        weg = sorted(
            g for g in zeilen | set(bisherige)
            if g not in neu.geraete
            or (g in bisherige and bisherige[g] != neu.geraete[g]))
        queue_weg = kyber_weg = 0
        with db:
            db.execute(
                "INSERT INTO geraetelisten (user_id, epoche, liste,"
                " sig_identitaet, sig_geraet, geaendert) VALUES (?,?,?,?,?,?)"
                " ON CONFLICT(user_id) DO UPDATE SET epoche=excluded.epoche,"
                " liste=excluded.liste, sig_identitaet=excluded.sig_identitaet,"
                " sig_geraet=excluded.sig_geraet, geaendert=excluded.geaendert",
                (uid, neu.epoche, neu.roh, neu.sig_identitaet, neu.sig_geraet,
                 time.time()))
            for g in weg:
                q, k = loesche_geraet(uid, g)
                queue_weg += q
                kyber_weg += k
            # Erledigt: Anfragen fuer Kennungen, die jetzt in der Liste stehen.
            db.executemany("DELETE FROM beitritte WHERE user_id=? AND device_id=?",
                           [(uid, g) for g in neu.geraete])
        kyber_zeilen_aendern(-kyber_weg)
    queue_zeilen_aendern(-queue_weg)

    # Erst NACH dem Speichern trennen: wer getrennt wird und sofort neu
    # verbindet, soll schon die neue Fassung sehen.
    await _melde_an_geraete(uid, weg, {"type": "abgemeldet", "epoche": neu.epoche},
                            schliessen=WS_ABGEMELDET)
    await _melde_an_geraete(uid, [g for g in neu.geraete if g not in weg],
                            {"type": "geraeteliste", "epoche": neu.epoche})
    return {"ok": True, "epoche": neu.epoche}


@app.post("/geraeteliste/beitritt")
async def beantrage_beitritt(req: BeitrittRequest, request: Request):
    """Ein Geraet, das nicht in der Liste steht, bittet darum (§8.5).

    Hier wird nichts entschieden. Die Anfrage liegt nur bereit, bis ein
    Mitglied sie bestaetigt — indem es eine neue Fassung der Liste
    veroeffentlicht — oder bis BEITRITT_TTL um ist.
    """
    if not herkunft_ok(request, "beitritt", cost=5):
        raise HTTPException(429, "zu viele Anfragen")
    a = lies_beitritt(req.anfrage, req.sig_identitaet, req.sig_geraet)
    with schreibsperre:
        liste = gespeicherte_liste(a.adresse)
        if liste is None:
            # Ohne Liste gibt es niemanden, der bestaetigen koennte; das Geraet
            # legt sie selbst an.
            raise HTTPException(409, "keine Geraeteliste")
        if a.device_id in liste[1]:
            raise HTTPException(409, "device_id ist schon vergeben")
        jetzt = time.time()
        with db:
            db.execute("DELETE FROM beitritte WHERE ts < ?", (jetzt - BEITRITT_TTL,))
            db.execute(
                "INSERT OR REPLACE INTO beitritte (user_id, device_id, anfrage,"
                " sig_identitaet, sig_geraet, ts) VALUES (?,?,?,?,?,?)",
                (a.adresse, a.device_id, a.roh, a.sig_identitaet, a.sig_geraet,
                 jetzt))
            # Hoechstens BEITRITTE_JE_ADRESSE, die neuesten bleiben.
            db.execute(
                "DELETE FROM beitritte WHERE user_id=?1 AND rowid NOT IN ("
                " SELECT rowid FROM beitritte WHERE user_id=?1"
                " ORDER BY ts DESC, rowid DESC LIMIT ?2)",
                (a.adresse, BEITRITTE_JE_ADRESSE))
    await _melde_an_geraete(a.adresse, list(liste[1]), {"type": "beitritt"})
    return {"ok": True}


@app.get("/geraeteliste/{user_id}/beitritte")
def hole_beitritte(user_id: str, request: Request):
    """Offene Beitrittsanfragen. Oeffentlich: sie enthalten nichts Geheimes,
    und jedes Mitglied prueft die Signaturen ohnehin selbst."""
    if not herkunft_ok(request, "pk"):
        raise HTTPException(429, "zu viele Anfragen")
    zeilen = db.execute(
        "SELECT anfrage, sig_identitaet, sig_geraet FROM beitritte"
        " WHERE user_id=? AND ts >= ? ORDER BY ts",
        (user_id, time.time() - BEITRITT_TTL)).fetchall()
    return {"beitritte": [{"anfrage": a, "sig_identitaet": b64e(i),
                           "sig_geraet": b64e(g)} for a, i, g in zeilen]}


# ------------------------------------------------------------------ WebSocket

# ═══════════════════════════════════════════════════════════════ Anstossen
#
# WAS DABEI RAUSGEHT: ein LEERER POST. Kein Absender, kein Inhalt, keine
# Anzahl. Der Push-Server erfaehrt nur, dass fuer dieses Thema etwas anliegt —
# die Nachricht selbst holt die App danach hier ab, verschluesselt wie immer.
#
# Ein Absender im Anstoss waere der schlimmste denkbare Fehler: er stuende
# unverschluesselt auf dem Sperrbildschirm und im Protokoll jedes Servers
# dazwischen.

PUSH_TIMEOUT = 8.0

# Nur eigene Push-Server. Ein Endpunkt, den ein Client frei waehlen darf,
# machte diesen Relay zu einem Werkzeug, mit dem sich beliebige fremde Server
# anschreiben lassen — jemand traegt eine fremde Adresse ein und laesst den
# Relay fuer sich klopfen.
PUSH_ERLAUBTE_HOSTS = {"push.bitdm.net"}

# WOHIN der POST tatsaechlich geht. Der Client nennt die oeffentliche Adresse;
# hinaus geht sie nicht.
#
# GRUND: die Unit sperrt jede ausgehende Verbindung (IPAddressDeny=any,
# deploy/install-relay.sh). Am 12.07.2026 wurde auf genau dieser Maschine ein
# Dienst gekapert und lud einen Miner nach — diese Sperre fuer eine
# Beschleunigung aufzumachen waere der falsche Tausch. Muss sie auch nicht:
# push.bitdm.net liegt auf demselben Rechner. Ist hier eine Basis gesetzt, wird
# deshalb nur der PFAD des GEPRUEFTEN Endpunkts uebernommen und an einen
# Zuhoerer auf dem Loopback gehaengt; 127.0.0.0/8 ist in derselben Unit ohnehin
# erlaubt. Der Host aus dem Endpunkt wird bewusst nicht benutzt.
#
# LEER ist der Vorgabewert, und das ist Absicht: der Loopback-Port des
# Push-Servers steht nirgends im Baum, und eine geratene Zahl waere ein leerer
# POST an irgendeinen fremden lokalen Dienst. Solange nichts gesetzt ist,
# bleibt es beim bisherigen Verhalten (POST an den Endpunkt selbst) — das
# betrifft Relays, die hinausduerfen; auf dem gesperrten Relay scheitert es
# weiterhin, aber seit _push_ging_daneben nicht mehr stumm.
PUSH_ZIEL_BASIS = os.getenv("BITDM_PUSH_TARGET", "").rstrip("/")


def anstoss_ziel(endpunkt: str) -> str:
    """Die Adresse, an die der leere POST wirklich geht."""
    if not PUSH_ZIEL_BASIS:
        return endpunkt
    return PUSH_ZIEL_BASIS + urllib.parse.urlsplit(endpunkt).path


# Hoechstens eine Klage je Stunde, mit Zaehler.
#
# WARUM ueberhaupt eine: die alte Fassung verschluckte jeden Fehlschlag
# wortlos. Auf dem gesperrten Relay ging seit der Einfuehrung des Anstosses
# kein einziger hinaus, und nichts zeigte es an.
# WARUM gedrosselt: der Anstoss haengt an jeder gepufferten Nachricht; ein
# kaputter Push-Server wuerde das Journal im Takt des Verkehrs fluten.
# WARUM zwei Zahlen und kein Woerterbuch je Adresse: ein Eintrag je Nutzer
# waechst unbegrenzt (dieselbe Falle wie bei _buckets/_nonces) und traegt
# nichts bei — was fehlt, ist die Tatsache, dass es klemmt, nicht bei wem.
PUSH_KLAGE_ABSTAND = float(os.getenv("BITDM_PUSH_KLAGE", 3600.0))

_push_klage_zuletzt: float | None = None
_push_fehler_seither = 0


def _push_ging_daneben(grund: str) -> None:
    """Meldet, dass ein Anstoss nicht ankam — hoechstens einmal je Stunde.

    IN DER MELDUNG STEHT WEDER ADRESSE NOCH ENDPUNKT. Der Endpunkt ist eine
    dauerhafte Geraetekennung (siehe den Kommentar an der Spalte in init_db),
    die Adresse der Empfaenger — beides aufzuschreiben waere genau die
    Aufzeichnung, die deploy/README.md unter "Was NICHT protokolliert wird"
    ausschliesst.
    """
    global _push_klage_zuletzt, _push_fehler_seither
    _push_fehler_seither += 1
    jetzt = time.monotonic()
    # None und nicht 0.0 als Startwert: time.monotonic() kann kurz nach dem
    # Hochfahren nahe null liegen, dann verschluckte 0.0 die erste Meldung.
    if (_push_klage_zuletzt is not None
            and jetzt - _push_klage_zuletzt < PUSH_KLAGE_ABSTAND):
        return
    print(f"[!] Anstoss geht nicht raus ({_push_fehler_seither} "
          f"Fehlversuche seit der letzten Meldung): {grund}")
    _push_klage_zuletzt = jetzt
    _push_fehler_seither = 0


def push_endpunkt_gueltig(url: str) -> bool:
    """Ob dieser Anstoss-Endpunkt angenommen wird."""
    if not isinstance(url, str) or len(url) > 512:
        return False
    try:
        teile = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if teile.scheme != "https":
        return False
    if teile.hostname not in PUSH_ERLAUBTE_HOSTS:
        return False
    # KEIN EIGENER PORT, KEINE BENUTZERANGABE (Audit vom 16.10.2026, SV-8).
    # Geprueft waren nur Schema, Host und Pfad: "https://push.bitdm.net:22/up..."
    # ging durch, und ohne BITDM_PUSH_TARGET ginge der leere POST genau
    # dorthin - an jeden Port der Maschine hinter push.bitdm.net, sobald der
    # Relay einmal hinaus darf. UnifiedPush-Endpunkte haben beides nie.
    # `.port` wirft bei einem Port ausserhalb 0..65535 (":99999").
    try:
        port = teile.port
    except ValueError:
        return False
    if port not in (None, 443) or teile.username is not None \
            or teile.password is not None:
        return False
    # UnifiedPush-Themen heissen "up" + Zufallszeichen. Alles andere waere
    # kein Anstoss-Endpunkt, sondern irgendein Pfad auf dem Push-Server.
    return re.fullmatch(r"/up[A-Za-z0-9_-]+", teile.path) is not None


# Laufende Anstoesse. asyncio haelt eine mit create_task gestartete Aufgabe
# nur SCHWACH fest; ohne einen eigenen Verweis darf der Speicherbereiniger
# sie mittendrin wegraeumen, und der Anstoss ginge still verloren (Hinweis in
# der Python-Doku zu create_task; von SonarQube Cloud am 18.10.2026 als
# python:S7502 gemeldet). Jede Aufgabe traegt sich hier ein und beim Ende
# wieder aus.
_laufende_anstoesse: set[asyncio.Task] = set()

# HOECHSTENS EIN ANSTOSS JE GERAET UNTERWEGS, und hoechstens so viele Geraete
# gleichzeitig (seit 23.10.2026, Audit vom 16.10.2026, SV-7).
#
# Vorher startete JEDE gepufferte Zeile eine eigene Aufgabe, ohne Deckel:
# wer an ein abwesendes Geraet mit Push-Endpunkt flutete - auch an eine
# eigene Zweitadresse -, hielt beliebig viele Aufgaben und Verbindungen zum
# Push-Server offen. Ein Geraet muss aber nur EINMAL geweckt werden, um alles
# abzuholen, was liegt.
#
# (Adresse, Geraet) -> ob waehrend des laufenden Anstosses noch eine Zeile
# kam. Dann geht nach dem laufenden GENAU EIN weiterer hinaus: eine Zeile, die
# nach dem Wecken eintraf, darf nicht ohne Anstoss liegen bleiben, falls das
# Geraet sich inzwischen schon wieder getrennt hat. Nur auf dem Event-Loop
# veraendert, braucht also keine Sperre.
_anstoss_nochmal: dict[tuple[str, int], bool] = {}

# Wie viele Geraete gleichzeitig angestossen werden. Darueber entfaellt der
# Anstoss: die Nachricht liegt in der Warteschlange, und die App holt sie
# beim naechsten Start - genau wie bei einem Push-Server, der nicht antwortet.
PUSH_LAUFEND_MAX = int(os.getenv("BITDM_PUSH_PARALLEL", 200))


def stosse_im_hintergrund_an(user_id: str, device_id: int) -> None:
    schluessel = (user_id, device_id)
    if schluessel in _anstoss_nochmal:
        _anstoss_nochmal[schluessel] = True
        return
    if len(_anstoss_nochmal) >= PUSH_LAUFEND_MAX:
        _push_ging_daneben(f"mehr als {PUSH_LAUFEND_MAX} Anstoesse gleichzeitig")
        return
    _anstoss_nochmal[schluessel] = False
    aufgabe = asyncio.create_task(_stosse_an_bis_nichts_nachkam(user_id, device_id))
    _laufende_anstoesse.add(aufgabe)
    aufgabe.add_done_callback(_laufende_anstoesse.discard)


async def _stosse_an_bis_nichts_nachkam(user_id: str, device_id: int) -> None:
    schluessel = (user_id, device_id)
    try:
        while True:
            await stosse_an(user_id, device_id)
            if not _anstoss_nochmal.get(schluessel):
                return
            _anstoss_nochmal[schluessel] = False
    finally:
        _anstoss_nochmal.pop(schluessel, None)


# EIN Client fuer alle Anstoesse, statt einer je Anstoss (SV-7).
#
# httpx.AsyncClient baut beim Anlegen einen TLS-Kontext samt CA-Buendel,
# synchron, also auf dem Event-Loop: gemessen 180 ms (Windows), unter Linux
# weniger, aber nicht null - je gepufferter Nachricht. Auch auf
# relay.bitdm.net, wo der POST ueber die Schleife und ohne TLS geht.
#
# MIT DER SCHLEIFE GEMERKT: eine Verbindung im Pool gehoert zu der Schleife,
# auf der sie aufgebaut wurde. Im Betrieb gibt es genau eine; die Tests
# starten je asyncio.run eine neue und bekommen dann einen neuen Client.
_push_klient: tuple[asyncio.AbstractEventLoop, httpx.AsyncClient] | None = None


def push_klient() -> httpx.AsyncClient:
    global _push_klient
    schleife = asyncio.get_running_loop()
    if _push_klient is None or _push_klient[0] is not schleife:
        _push_klient = (schleife, httpx.AsyncClient(timeout=PUSH_TIMEOUT))
    return _push_klient[1]


async def schliesse_push_klient() -> None:
    """Beim Herunterfahren (lifespan)."""
    global _push_klient
    if _push_klient is not None:
        klient, _push_klient = _push_klient[1], None
        await klient.aclose()


async def stosse_an(user_id: str, device_id: int) -> None:
    # JE GERAET: der Anstoss-Endpunkt steht in der Geraetezeile und ist damit
    # von selbst geraetegenau. Ein Anstoss je gepufferter Zeile heisst bei
    # Fanout einen je Zielgeraet — was richtig ist, denn nur das Geraet mit
    # dieser Zeile hat etwas abzuholen.
    #
    # Dieser Lesezugriff steht bewusst OHNE schreibsperre da: stosse_an ist
    # async und hat unten ein await — die Sperre bis dorthin zu halten, waere
    # genau der Deadlock, vor dem der Kommentar an schreibsperre warnt.
    # Schlimmstenfalls sieht er einen Endpunkt, der gleich ueberschrieben wird;
    # daraus wird ein leerer POST an die vorige Adresse.
    row = db.execute(
        "SELECT push_endpoint FROM identities WHERE user_id=? AND device_id=?",
        (user_id, device_id),
    ).fetchone()
    if row is None or not row[0]:
        return
    try:
        # NICHT follow_redirects=True. httpx folgt ab Werk nicht; ein
        # Umzug wuerde den POST sonst an einen beliebigen Host tragen und
        # den Host-Pin aus PUSH_ERLAUBTE_HOSTS aushebeln.
        antwort = await push_klient().post(anstoss_ziel(row[0]), content=b"")
    except Exception as exc:
        # Ein Anstoss, der nicht ankommt, ist kein Fehler des Absenders — die
        # Nachricht liegt in der Warteschlange und wird beim naechsten Start
        # der App zugestellt. Gemeldet wird er trotzdem: sonst faellt ein
        # dauerhaft kaputter Push-Server niemandem auf.
        _push_ging_daneben(f"{type(exc).__name__}: {exc}")
        return
    # httpx wirft bei 4xx/5xx NICHT von sich aus. Ohne diese Zeile bliebe ein
    # antwortender, aber ablehnender Push-Server genauso unsichtbar wie vorher
    # der gesperrte Connect.
    if antwort.status_code >= 400:
        _push_ging_daneben(f"HTTP {antwort.status_code}")


# Wie viele Verbindungen gerade im Vorraum stehen: angenommen, aber noch
# nicht angemeldet. Nur auf dem Event-Loop veraendert, braucht also keine
# Sperre. Siehe WS_VORRAUM_MAX.
_ws_im_vorraum = 0

# Steht fuer einen Rahmen, der kein JSON-Text war.
KAPUTT = object()


async def lies_rahmen(ws: WebSocket):
    """Einen Rahmen lesen. Rueckgabe: der JSON-Wert oder KAPUTT.

    Frueher ging jeder kaputte Rahmen als Ausnahme durch den ganzen Handler:
    ein BINAERER Rahmen warf in Starlettes receive_json KeyError('text'),
    tief verschachteltes JSON RecursionError, ungueltiges UTF-8 bzw. JSON
    ValueError. Keiner davon stand in einer Fangliste — die Verbindung riss
    ohne Close-Frame ab, und jeder Versuch schrieb einen Traceback ins
    Journal, vor der Anmeldung ohne jede Bremse (Audit vom 25.09.2026,
    proof_ws.py P1/P2).

    WebSocketDisconnect und RuntimeError (Verbindung schon zu) laufen
    unveraendert durch: das ist kein kaputter Rahmen, sondern das Ende.
    """
    try:
        return await ws.receive_json()
    except (KeyError, TypeError, ValueError, RecursionError):
        return KAPUTT


class Rahmenbudget:
    """Token-Bucket JE VERBINDUNG fuer jeden Rahmen. Siehe RAHMEN_BURST.

    Lebt in der Verbindung und nicht in _buckets: er stirbt mit ihr und kann
    den Speicher deshalb nicht fuellen.
    """

    def __init__(self) -> None:
        self.vorrat = RAHMEN_BURST
        self.zuletzt = time.monotonic()

    def nimm(self) -> bool:
        jetzt = time.monotonic()
        self.vorrat = min(RAHMEN_BURST,
                          self.vorrat + (jetzt - self.zuletzt) * RAHMEN_REFILL_PER_SEC)
        self.zuletzt = jetzt
        if self.vorrat < 1.0:
            return False
        self.vorrat -= 1.0
        return True


async def _vorraum(ws: WebSocket):
    """Annehmen, Challenge, Signatur pruefen.

    Rueckgabe: (user_id, device_id, antwortrahmen) nach gelungener Anmeldung,
    sonst None (die Verbindung ist dann schon beantwortet bzw. zu).
    """
    await ws.accept()
    user_id = ws.query_params.get("user_id", "")

    # Ohne `device_id` in der Query ist es Geraet 1 — ein Client, der nichts
    # von Geraeten weiss, landet damit auf seiner bisherigen Zeile.
    roh_geraet = ws.query_params.get("device_id")
    try:
        device_id = 1 if roh_geraet is None else int(roh_geraet)
    except ValueError:
        # Kein eigener Fehlerzweig: eine Kennung, die keine Zahl ist, gibt es
        # unter keiner Adresse, und die Abfrage darunter antwortet ohnehin
        # schon "erst /register aufrufen". Ein zweiter Zweig waere eine zweite
        # Stelle, an der etwas anderes herauskaeme.
        device_id = -1
    if not geraetekennung_moeglich(device_id):
        # Derselbe Ausgang wie oben, und aus demselben Grund: eine Kennung
        # ausserhalb des Bereichs gibt es unter keiner Adresse. Ohne diese
        # Zeile ginge sie unveraendert in die SQLite-Bindung darunter — und
        # `?device_id=9223372036854775808` risse die Verbindung ungefangen ab,
        # unauthentifiziert und ungebremst. -1 passt in die Bindung.
        device_id = -1

    # DIE GERAETELISTE ZUERST, vor der Frage nach der Zeile. Ein abgemeldetes
    # Geraet hat keine Zeile mehr und bekaeme sonst "erst /register aufrufen"
    # mit 4401 — und genau darauf meldet sich die App von selbst neu an. 4410
    # sagt ihr: nicht wieder anmelden, sondern die Liste ansehen.
    liste = gespeicherte_liste(user_id)
    if liste is not None and device_id not in liste[1]:
        await ws.send_json({"type": "abgemeldet", "epoche": liste[0]})
        await ws.close(code=WS_ABGEMELDET)
        return None
    geraeteschluessel = liste[1][device_id] if liste is not None else None

    row = db.execute(
        "SELECT identity_key FROM identities WHERE user_id=? AND device_id=?",
        (user_id, device_id),
    ).fetchone()
    if row is None:
        await ws.send_json({"type": "error", "reason": "erst /register aufrufen"})
        await ws.close(code=4401)
        return
    identity_key = row[0]

    # ---- Challenge-Response ----
    nonce = secrets.token_bytes(32)
    # `relay` nur, wenn dieser Relay die neue Form kennt (siehe
    # ANMELDUNG_WS_PRAEFIX). Apps bis 2.0.0 lesen nur `nonce`.
    namen = relay_namen()
    await ws.send_json({"type": "challenge", "nonce": b64e(nonce),
                        **({"relay": list(namen)} if namen else {})})
    try:
        # 10 statt 30 Sekunden, siehe WS_ANMELDEFRIST.
        reply = await asyncio.wait_for(lies_rahmen(ws), timeout=WS_ANMELDEFRIST)
    except (WebSocketDisconnect, asyncio.TimeoutError, RuntimeError):
        return None

    # Kein JSON-Objekt (binaerer Rahmen, Liste, Zahl, kaputtes JSON): wie eine
    # Antwort ohne Signatur behandeln. Das fuehrt in den ordentlichen
    # Ausgang darunter — auth_result ok=False und 4403 — statt in einen
    # Traceback.
    if not isinstance(reply, dict):
        reply = {}
    roh_signatur = reply.get("signature", "")
    try:
        signature = b64d(roh_signatur) if isinstance(roh_signatur, str) else b""
    except ValueError:
        signature = b""

    # WAS SIGNIERT WIRD, haengt daran, ob die Query eine Kennung TRUEG — nicht
    # daran, welche. Sonst liesse sich eine Signatur, die fuer Geraet A
    # abgefangen wurde, unter Geraet B einreichen; das Nonce ist zwar je
    # Verbindung frisch, aber es steht offen auf der Leitung.
    #
    # Ein Herunterhandeln faellt geschlossen aus: streicht jemand `device_id`
    # aus der Query eines neuen Clients, erwartet der Server 32 Byte, der
    # Client hat 36 signiert -> 4403. Und ohne den privaten
    # Identitaetsschluessel kommt ueberhaupt keine Signatur zustande.
    #
    # device_id ist an dieser Stelle nachweislich eine gespeicherte Kennung
    # (die Abfrage oben hat getroffen), passt also in 4 Byte unsigned.
    #
    # DIE NEUE FORM (KR-2) nennt das Geraet ausdruecklich, also auch Geraet 1
    # ohne Kennung in der Query - eine Signatur fuer Geraet A ist damit nie
    # eine fuer B. Welche Form gilt, sagt das Feld `relay` der Antwort.
    zulaessig, host = angemeldeter_relay(reply.get("relay"))
    if not zulaessig:
        await ws.send_json({"type": "auth_result", "ok": False})
        await ws.close(code=4403)
        return None
    if host is not None:
        erwartet = ws_anmelde_nachricht(host, user_id, device_id, nonce)
    else:
        erwartet = (nonce if roh_geraet is None
                    else nonce + device_id.to_bytes(4, "big"))

    if not verify_signature(identity_key, erwartet, signature):
        await ws.send_json({"type": "auth_result", "ok": False})
        await ws.close(code=4403)
        return None
    # Mit Liste zusaetzlich der Geraeteschluessel ueber dieselben Bytes. Den
    # Identitaetsschluessel hat auch ein abgemeldetes Geraet — nur dieser
    # Schluessel unterscheidet die Geraete einer Adresse.
    if geraeteschluessel is not None and not geraete_signatur_ok(
            geraeteschluessel, erwartet, reply.get("geraete_signatur")):
        await ws.send_json({"type": "auth_result", "ok": False})
        await ws.close(code=4403)
        return None
    return user_id, device_id, reply, geraeteschluessel


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    global _ws_im_vorraum
    # DER VORRAUM IST GEDECKELT. Vor der Anmeldung kostet eine Verbindung
    # einen Angreifer nichts; ueber Tor greift auch kein Limit je IP. Am
    # Deckel wird geschlossen, bevor irgendetwas anderes passiert — vor dem
    # accept wird daraus bei uvicorn eine HTTP-Absage (403) ohne Upgrade.
    if _ws_im_vorraum >= WS_VORRAUM_MAX:
        try:
            await ws.close(code=1013)
        except Exception:
            pass
        return
    _ws_im_vorraum += 1
    try:
        angemeldet = await _vorraum(ws)
    finally:
        _ws_im_vorraum -= 1
    if angemeldet is None:
        return
    user_id, device_id, reply, geraeteschluessel = angemeldet

    # Ob die Gegenseite den Empfangsnachweis beherrscht. Steht im SELBEN
    # Rahmen wie die Signatur, weil er ohnehin kommen muss und weil die
    # Antwort damit VOR der ersten Zustellung vorliegt. Wer das Feld nicht
    # kennt, bekommt unveraendert das bisherige Verhalten -- ein Server, der
    # auf einen Nachweis wartet, den ein altes Telefon nie schickt, waere
    # schlimmer als der Verlust, den das hier behebt.
    #
    # `reply` ist hier immer ein dict — _vorraum macht aus allem anderen {}.
    nachweis = reply.get("empfangsnachweis") is True

    # Der Rueckspiegel ist reine Diagnose — aeltere Clients lesen aus
    # auth_result nur `ok` und ignorieren alles andere. Er macht im Test die
    # Frage "hat der Server mich verstanden" ueberhaupt beantwortbar; ein
    # neuer Client, der das Flag versehentlich nicht setzt, sieht die `q`
    # trotzdem und faellt sonst nirgends auf.
    # Lebenszeichen dieses Geraets, einmal je Verbindung. Daran haengt
    # GERAET_TTL: ohne diese Zeile waere jedes Geraet nach 30 Tagen weg,
    # gleichgueltig wie oft es sich verbunden hat.
    with schreibsperre, db:
        db.execute("UPDATE identities SET last_seen=? WHERE user_id=? AND device_id=?",
                   (time.time(), user_id, device_id))

    # `device_id` im Rueckspiegel ist reine Diagnose, dieselbe Begruendung wie
    # beim Empfangsnachweis: ein Client, der versehentlich die falsche Kennung
    # schickt, ist von aussen sonst nicht von einem alten zu unterscheiden.
    # `fluechtig` kuendigt an, dass dieser Relay fluechtige Rahmen kennt (siehe
    # unten beim Versand). Ein Client sendet sie NUR, wenn das hier steht —
    # ein alter Relay wuerde sie sonst puffern und den Empfaenger per Anstoss
    # wecken, fuer ein "tippt gerade", das Stunden spaeter nichts mehr heisst.
    antwort = {"type": "auth_result", "ok": True,
               "empfangsnachweis": nachweis, "device_id": device_id,
               "fluechtig": True}
    if NEUESTE_FASSUNG:
        antwort["neueste"] = NEUESTE_FASSUNG
    await ws.send_json(antwort)

    # Eine aktive Verbindung je (Adresse, GERAET): eine neue verdraengt nur die
    # alte DESSELBEN Geraets. Frueher verdraengte sie jede Verbindung der
    # Adresse — damit warfen sich zwei Geraete mit denselben zwoelf Woertern
    # gegenseitig hinaus, immer abwechselnd, und keines merkte etwas.
    old = connections.get(user_id, {}).get(device_id)
    if old is not None:
        # Breit gefangen, mit Absicht: was hier schiefgeht, betrifft eine
        # Verbindung, die ohnehin endet — die NEUE darf nicht daran haengen.
        # `except RuntimeError` war zu eng. Schiebt der Server der alten
        # Verbindung gerade noch ihren Rueckstand hinterher, schreiben zwei
        # Aufgaben auf dasselbe Protokoll; was close() dann wirft, haengt
        # daran, welche WebSocket-Umsetzung uvicorn gerade gewaehlt hat
        # (websockets oder wsproto). Eine Typenliste waere an eine Fassung
        # gebunden — und jeder Wurf, der hier durchkaeme, risse die neue
        # Verbindung mit, bevor sie ueberhaupt in `connections` steht: der
        # Nutzer bliebe stumm, bis er die App neu startet.
        # asyncio.CancelledError erbt von BaseException und wird davon NICHT
        # verschluckt, ein Herunterfahren bleibt also sauber.
        try:
            await old.close(code=4409)
        except Exception:
            pass

    # AB HIER GEHOEREN EINTRAGEN UND AUFRAEUMEN ZUSAMMEN. Jeder Weg aus dieser
    # Funktion muss durch das `finally` ganz unten, sonst bleibt ein toter
    # Socket in `connections` stehen — und dann schreibt jeder Absender an
    # diese Adresse in den toten Socket, statt zu puffern: seine Nachricht ist
    # weder zugestellt noch gepuffert, sein `ack` bleibt aus, und seine eigene
    # Verbindung stirbt gleich mit. Das `try:` steht deshalb HIER und nicht
    # erst vor der Hauptschleife: die Nachzustellung ist genau die Stelle, an
    # der es reisst, weil dort der ganze Rueckstand durch den Socket geht.
    connections.setdefault(user_id, {})[device_id] = ws
    nachweisfaehig.setdefault(user_id, {})[device_id] = nachweis
    try:
        # NOCH EINMAL DIE LISTE, jetzt wo die Leitung in `connections` steht.
        # Zwischen der Pruefung im Vorraum und hier lagen Wartepunkte (die
        # Challenge, auth_result, die Verdraengung). Faellt eine Abmeldung
        # genau dorthin, fand setze_geraeteliste diese Leitung noch nicht in
        # `connections` — und das abgemeldete Geraet bliebe verbunden. Ab
        # hier sieht jede spaetere Abmeldung die Leitung; was vorher kam,
        # faengt diese Abfrage. Auch ein Geraet, das sich OHNE Liste anmeldete,
        # waehrend ein anderes sie gerade anlegte: es hat keinen
        # Geraeteschluessel vorgezeigt und muss neu anmelden.
        jetzt_liste = gespeicherte_liste(user_id)
        if (jetzt_liste is not None
                and jetzt_liste[1].get(device_id) != geraeteschluessel):
            await ws.send_json({"type": "abgemeldet", "epoche": jetzt_liste[0]})
            await ws.close(code=WS_ABGEMELDET)
            return

        # ---- wartende Nachrichten zustellen ----
        #
        # NUR die dieses Geraets. `recipient` allein trennt nicht mehr: beide
        # Geraete haben dieselbe Adresse, und ohne `recipient_device` bekaeme
        # jedes Geraet die Umschlaege des anderen — verschluesselt gegen eine
        # Sitzung, die es nicht hat, und der erste Fehlversuch schreibt den
        # Ratchet-Fortschritt fest.
        rows = db.execute(
            "SELECT id, sender, sender_device, ciphertext, ts FROM queue"
            " WHERE recipient=? AND recipient_device=? ORDER BY id",
            (user_id, device_id)
        ).fetchall()
        zugestellt: list[int] = []
        for row_id, sender, sender_device, ciphertext, ts in rows:
            await ws.send_json({
                "type": "message",
                "from": sender,
                # OHNE DIES IST DAS GANZE VORHABEN WIRKUNGSLOS: der Empfaenger
                # waehlt daran die Sitzung (name:geraet). Faechert ein Absender
                # mit zwei Geraeten an mich, kommen zwei Umschlaege an; beide
                # gegen name:1 zu probieren, laesst einen davon immer
                # scheitern — und der Fehlversuch rueckt den Ratchet.
                "from_device": sender_device,
                "ciphertext": b64e(ciphertext),
                "ts": ts,
                # Die Kennung der Warteschlangenzeile. Nur gepufferte
                # Nachrichten tragen sie -- live weitergereichte haben keine
                # Zeile, die man bestaetigen koennte. Sie geht auch an
                # Clients hinaus, die damit nichts anfangen: ein unbekanntes
                # Feld kostet sie nichts, und zwei Zustellwege waeren zwei
                # Gelegenheiten, einen davon falsch zu machen.
                "q": row_id,
            })
            zugestellt.append(row_id)

        # HIER LAG DER VERLUST: geloescht wurde, sobald der Rahmen im
        # Schreibpuffer stand. `send_json` wartet nur, bis der Puffer ihn
        # angenommen hat (websockets: write_frame -> transport.write ->
        # drain, und drain kehrt unterhalb der 64-KiB-Wassermarke sofort
        # zurueck). Reisst die Strecke danach ab, ist die Nachricht weg und
        # der Absender hat sein ack seit Tagen.
        #
        # Wer den Nachweis beherrscht, bekommt die Zeilen aufgehoben, bis er
        # meldet, dass sie bei ihm liegen. Meldet er nie, bleiben sie bis
        # QUEUE_TTL_SECONDS liegen und werden noch einmal zugestellt --
        # doppelt ist harmlos (die Ratchet-Schicht verwirft sie still),
        # verloren nicht.
        if zugestellt and not nachweis:
            with schreibsperre, db:
                # Der Geraetefilter steht auch hier, obwohl die Kennungen aus
                # der eigenen Abfrage oben stammen: es ist dasselbe DELETE wie
                # im Empfangsnachweis, und zwei Fassungen derselben Bedingung
                # sind zwei Gelegenheiten, eine davon zu vergessen.
                db.executemany(
                    "DELETE FROM queue WHERE id=? AND recipient=?"
                    " AND recipient_device=?",
                    [(i, user_id, device_id) for i in zugestellt])
            queue_zeilen_aendern(-len(zugestellt))

        # Zaehlt JE GERAET — sonst saehe ein frisch gekoppeltes Zweitgeraet den
        # vollen Vorrat des Erstgeraets und lieferte nie nach.
        otk_left, kyber_left, hat_kyber = db.execute(
            "SELECT"
            " (SELECT COUNT(*) FROM one_time_prekeys"
            "   WHERE user_id=?1 AND device_id=?2),"
            " (SELECT COUNT(*) FROM one_time_kyber_prekeys"
            "   WHERE user_id=?1 AND device_id=?2),"
            " (SELECT kyber_prekey IS NOT NULL FROM identities"
            "   WHERE user_id=?1 AND device_id=?2)",
            (user_id, device_id)
        ).fetchone()
        # DER KYBER-VORRAT LOEST DIESELBE NACHRICHT AUS, mit einem Feld mehr.
        #
        # Keine eigene Nachrichtenart, weil die App auf `prekeys_low` ohnehin
        # das GANZE Buendel neu anmeldet (register() ersetzt beide Vorraete
        # auf einmal) — zwei Ausloeser fuer denselben Weg waeren zwei
        # Gelegenheiten, einen davon nicht zu verdrahten. `remaining` behaelt
        # seine Bedeutung (EC-Vorrat), damit keine bestehende Auswertung still
        # etwas anderes zaehlt; `kyber_remaining` steht daneben, NUR fuer
        # Geraete mit Kyber. Eine alte App bekommt die Nachricht deshalb nie
        # wegen Kyber: ohne Last-Resort-Schluessel ist ihr Kyber-Vorrat immer
        # 0, und sie meldete sich sonst bei jeder Verbindung neu an, ohne dass
        # sich je etwas aenderte.
        #
        # AUS DEMSELBEN GRUND NICHT AM DACH (KYBER_OTK_MAX_GESAMT): bekaeme das
        # Geraet beim Nachliefern nicht mindestens OTK_LOW_WATERMARK Schluessel
        # unter, stuende es danach wieder unter der Schwelle — und die App
        # meldete sich bei jeder Verbindung vergeblich neu an. Ist der
        # EC-Vorrat knapp, geht die Nachricht trotzdem, wie bisher.
        platz_fuer_geraet = KYBER_OTK_MAX_GESAMT - (_kyber_zeilen - kyber_left)
        kyber_knapp = (bool(hat_kyber) and kyber_left < OTK_LOW_WATERMARK
                       and platz_fuer_geraet >= OTK_LOW_WATERMARK)
        if otk_left < OTK_LOW_WATERMARK or kyber_knapp:
            meldung = {"type": "prekeys_low", "remaining": otk_left}
            if hat_kyber:
                meldung["kyber_remaining"] = kyber_left
            await ws.send_json(meldung)

        # ---- Hauptschleife: Umschlaege weiterleiten ----
        budget = Rahmenbudget()
        while True:
            data = await lies_rahmen(ws)

            # JEDER Rahmen kostet, auch einer, der gleich verworfen wird —
            # sonst waeren genau die Arten frei, an denen keine andere Bremse
            # haengt (empfangen, geraeus, Unbekanntes, Kaputtes).
            if not budget.nimm():
                try:
                    await ws.close(code=4429)
                except Exception:
                    pass
                break

            # Nur JSON-OBJEKTE sind Rahmen. Eine Liste, eine Zahl oder
            # kaputtes JSON riss frueher mit AttributeError an data.get die
            # Verbindung ab (proof_ws.py P3). Still verwerfen, wie eine
            # unbekannte Art.
            if not isinstance(data, dict):
                continue

            # ── Empfangsnachweis ──────────────────────────────────────────
            #
            # Das Gegenstueck zum "q" oben. Der Client schickt es ERST,
            # nachdem er die Nachricht dauerhaft abgelegt hat; vorher waere
            # der Verlust nur von der Leitung in die App verschoben.
            #
            # KEINE ANTWORT DARAUF. Der Client koennte mit ihr nichts
            # anfangen: ueberlebt die Zeile, kommt sie beim naechsten
            # Verbinden noch einmal und wird dort als Doppelgaenger
            # verworfen.
            #
            # AUCH NICHT AUF msg_limit_ok GEBUCHT: die Bremse dort zaehlt
            # Nachrichten, die auf die Platte gehen. Wer viel bestaetigt, hat
            # viel bekommen -- ihn dafuer zu drosseln hiesse, ausgerechnet
            # den Nachweis zu verhindern, an dem das Loeschen haengt.
            if data.get("type") == "empfangen":
                ids = data.get("ids")
                if isinstance(ids, list):
                    # ABSCHNEIDEN VOR DEM AUFBAUEN, nicht danach.
                    #
                    # Hier stand `eigene[:QUEUE_MAX_PER_USER]` erst hinter der
                    # Listenkomposition. Die lief damit ueber die VOLLE Liste,
                    # und weil dieser Zweig ausdruecklich von jeder Bremse
                    # ausgenommen ist, war das eine offene Tuer: ein einziger
                    # Rahmen von 16 MiB (uvicorns Vorgabe) enthaelt 8,4
                    # Millionen Kennungen, der Aufbau belegte gemessen 579 MiB
                    # und blockierte den Event-Loop 2,1 s am Stueck. Die Unit
                    # hat MemoryMax=512M -- der Dienst wurde vom cgroup-OOM
                    # erschlagen und riss alle Verbindungen mit.
                    #
                    # Gemessen am 27.07.2026 von einem Widerlegungsagenten,
                    # gegen den echten ws_endpoint mit angemeldetem Client.
                    #
                    # Mehr Zeilen als QUEUE_MAX_PER_USER kann eine Adresse nie
                    # offen haben; alles darueber ist Muell und wird gar nicht
                    # erst angesehen.
                    ids = ids[:QUEUE_MAX_PER_USER]

                    # `AND recipient=?` ist nicht Sorgfalt, sondern noetig:
                    # die Kennungen sind fortlaufend und damit zu erraten.
                    # Ohne die Bedingung koennte jeder Angemeldete fremde
                    # Warteschlangen leeren. bool ist in Python ein int --
                    # deshalb die zweite Pruefung, wie schon bei der Groesse
                    # der Blob-Marke.
                    #
                    # Die Obergrenze ist dieselbe Sache wie in
                    # geraetekennung_moeglich: eine Kennung jenseits 2**63
                    # wirft beim Binden OverflowError, den die Fangliste
                    # dieser Schleife nicht kennt -- und der reisst die
                    # Verbindung ungefangen ab. `id` ist der rowid der
                    # Warteschlange und liegt immer darunter; alles darueber
                    # traefe ohnehin keine Zeile.
                    #
                    # `AND recipient_device=?` IST DIE GEFAEHRLICHSTE EINZELNE
                    # STELLE DES GANZEN UMBAUS. Seit die Warteschlange am
                    # Geraet haengt, trennt die Adresse allein nichts mehr:
                    # beide Geraete FUEHREN dieselbe, beide sind angemeldet,
                    # und die Kennungen sind zu erraten. Ohne die Bedingung
                    # koennte Geraet A die noch nicht zugestellte Post von
                    # Geraet B loeschen -- stiller Verlust, kein Fehler, keine
                    # Spur. Das Geraet kommt aus der VERBINDUNG, nie aus dem
                    # Rahmen.
                    eigene = [(i, user_id, device_id) for i in ids
                              if isinstance(i, int) and not isinstance(i, bool)
                              and 0 < i < 2**63]
                    if eigene:
                        with schreibsperre, db:
                            cur = db.executemany(
                                "DELETE FROM queue WHERE id=? AND recipient=?"
                                " AND recipient_device=?",
                                eigene)
                        # rowcount summiert bei executemany ueber alle
                        # Durchlaeufe; erraten Kennungen treffen nichts und
                        # zaehlen deshalb auch nicht mit.
                        queue_zeilen_aendern(-max(0, cur.rowcount))
                continue

            # ── Anstoss-Endpunkt eintragen oder loeschen ──────────────────
            #
            # UEBER DIE BESTEHENDE VERBINDUNG, nicht ueber einen eigenen
            # HTTP-Pfad. Hier ist schon nachgewiesen, wem diese Adresse
            # gehoert — ein eigener Pfad muesste denselben Nachweis noch
            # einmal fuehren, und jede zweite Umsetzung desselben Nachweises
            # ist eine Gelegenheit, ihn falsch zu machen.
            if data.get("type") == "push_endpoint":
                endpunkt = data.get("endpoint")
                # JE GERAET, weil die Spalte an der Geraetezeile haengt: der
                # Endpunkt ist die Kennung eines bestimmten Telefons, und ein
                # zweites Geraet darf ihn nicht ueberschreiben.
                if endpunkt in (None, ""):
                    with schreibsperre, db:
                        db.execute(
                            "UPDATE identities SET push_endpoint=NULL"
                            " WHERE user_id=? AND device_id=?",
                            (user_id, device_id),
                        )
                    await ws.send_json({"type": "push_ok", "set": False})
                elif push_endpunkt_gueltig(endpunkt):
                    with schreibsperre, db:
                        db.execute(
                            "UPDATE identities SET push_endpoint=?"
                            " WHERE user_id=? AND device_id=?",
                            (endpunkt, user_id, device_id),
                        )
                    await ws.send_json({"type": "push_ok", "set": True})
                else:
                    await ws.send_json(
                        {"type": "error", "reason": "Anstoss-Endpunkt ungueltig"}
                    )
                continue

            # ── Erlaubnis zum Ablegen im Zwischenlager ────────────────────
            #
            # DIE KENNUNG SUCHT SICH DER CLIENT AUS. "Blind" unterschreibt
            # dieser Server sie NICHT — sie steht im Klartext in diesem
            # Rahmen, und er rechnet sie in die Marke. Er SPEICHERT sie nur
            # nicht (blob_marken hat keine Spalte dafuer) und schreibt sie
            # nirgends hin. Wer den laufenden Prozess beobachten kann, sieht
            # die Verbindung Adresse -> Kennung trotzdem; bis zum 25.09.2026
            # stand hier und in docs/ZWISCHENLAGER.md das Gegenteil.
            #
            # Wuerfelte er sie selbst, wuerde er sie auf jeden Fall kennen
            # und muesste sie zurueckschicken — der Unterschied ist also nur,
            # dass nichts davon liegen bleibt.
            #
            # Dass der Client sie waehlt, kostet nichts: eine schon belegte
            # Kennung weist das Lager mit 409 ab, und 32 Byte Zufall zu
            # erraten ist keine Angriffsflaeche.
            if data.get("type") == "blob_marke":
                kennung = data.get("kennung", "")
                groesse = data.get("groesse")
                marken_ref = {"kennung": kennung} if isinstance(kennung, str) else {}

                if not isinstance(kennung, str) or not BLOB_KENNUNG_MUSTER.fullmatch(kennung):
                    await ws.send_json({"type": "error", "reason": "Kennung ungueltig"})
                    continue
                if not isinstance(groesse, int) or isinstance(groesse, bool) \
                        or not 0 < groesse <= BLOB_MAX_BYTES:
                    await ws.send_json(
                        {"type": "error", "reason": "Groesse ungueltig", **marken_ref}
                    )
                    continue

                # BLEIBT AN DER ADRESSE UND NICHT AM GERAET, und das ist eine
                # Entscheidung, keine Auslassung: mit device_id bekaeme
                # dieselbe Person mit 5 Geraeten 125 GiB am Tag statt 25 — die
                # Verteidigung waere fuer den Preis eines zweiten Geraets
                # aufzuheben, und ein Geraet anzulegen kostet nichts. Aus
                # demselben Grund bleibt `blob_marken` ohne Geraetespalte.
                # Nicht "der Vollstaendigkeit halber" nachtragen.
                #
                # Die Tagesmenge. Sie wird beim AUSSTELLEN gezaehlt, nicht beim
                # Hochladen — dieser Server erfaehrt nie, ob wirklich
                # hochgeladen wurde. Wer sich Marken holt und sie verfallen
                # laesst, verbraucht damit sein eigenes Kontingent; das ist die
                # richtige Richtung fuer den Irrtum.
                # Angerechnet wird mindestens BLOB_MINDESTMENGE, siehe dort. Die
                # Marke selbst gilt weiter fuer genau `groesse` Bytes.
                angerechnet = max(groesse, BLOB_MINDESTMENGE)
                # Hoechstens 25 Zeilen, siehe BLOB_STUNDE. Eine Summe ueber
                # den GANZEN Relay steht hier nicht mehr (SV-1/SV-2): die
                # zaehlt das Lager, nach Bytes, die wirklich ankommen. Ist es
                # voll, antwortet es auf den Upload mit 507, und die App zeigt
                # das wie eine volle Platte ("spaeter noch einmal").
                verbraucht = blob_menge_heute(user_id)
                if verbraucht + angerechnet > BLOB_TAGESMENGE:
                    await ws.send_json({
                        "type": "error",
                        "reason": "Tagesmenge erschoepft",
                        "frei": max(0, BLOB_TAGESMENGE - verbraucht),
                        **marken_ref,
                    })
                    continue

                ablauf = int(time.time()) + BLOB_MARKE_TTL
                try:
                    marke = blob_marke(kennung, groesse, ablauf)
                except OSError:
                    # Das Geheimnis fehlt oder ist nicht lesbar. NICHT so tun,
                    # als laege es am Client: sonst sucht jemand tagelang in
                    # der App nach einem Fehler, der auf dem Server sitzt.
                    await ws.send_json({
                        "type": "error",
                        "reason": "Zwischenlager nicht eingerichtet",
                        **marken_ref,
                    })
                    continue

                # Das await bleibt AUSSERHALB der Sperre — siehe die
                # Begruendung bei schreibsperre.
                with schreibsperre, db:
                    blob_menge_anrechnen(user_id, angerechnet)
                await ws.send_json({
                    "type": "blob_marke_ok",
                    "kennung": kennung,
                    "groesse": groesse,
                    "ablauf": ablauf,
                    "marke": marke,
                    "ablegen": f"{BLOB_BASIS}/ablegen/{kennung}",
                    "holen": f"{BLOB_BASIS}/blob/{kennung}",
                    "wegwerfen": f"{BLOB_BASIS}/wegwerfen/{kennung}",
                })
                continue

            # TARNVERKEHR ("geraeus", seit 25.09.2026): sieht von aussen aus
            # wie eine Nachricht und wird hier verworfen — kein Speichern,
            # keine Bremse ausser dem Rahmenbudget oben.
            #
            # ABER MIT EINER ANTWORT, die aussieht wie das `ack` auf eine
            # echte Nachricht. Bis zum 25.09.2026 blieb sie aus, und genau das
            # verriet ihn: auf eine echte Nachricht folgt nach wenigen
            # Millisekunden ein kleiner Rahmen zurueck, auf Tarnverkehr nichts.
            # Wer die Leitung beobachtet, zaehlte einfach die Antworten.
            #
            # DERSELBE AUFBAU WIE DAS ECHTE ACK: {"type","to","id"} in dieser
            # Reihenfolge, `to` als 56 Zeichen (die App schickt eine
            # Zufallsadresse aus demselben Alphabet), `id` nur, wenn es eine
            # Zeichenkette ist. Die App ordnet ein `ack` ueber `id` einem
            # wartenden Versand zu; fuer Tarnverkehr wartet keiner, das `ack`
            # faellt dort still durch (relay_client.dart, _loeseAckAus).
            if data.get("type") == "geraeus":
                tarn_an = data.get("to")
                tarn_id = data.get("id")
                await ws.send_json({
                    "type": "ack",
                    "to": tarn_an[:56] if isinstance(tarn_an, str) else "",
                    **({"id": tarn_id} if isinstance(tarn_id, str) else {}),
                })
                continue

            if data.get("type") != "message":
                continue

            to = data.get("to", "")
            raw_ct = data.get("ciphertext", "")

            # Optionale Kennung des Clients, die in Bestaetigung und Fehler
            # zurueckgespiegelt wird.
            #
            # Ohne sie traegt die Bestaetigung nur die Zieladresse — und ein
            # Client, der zwei Nachrichten an denselben Kontakt geschickt hat,
            # kann nicht sagen, welche davon angekommen ist. Genau das braucht
            # er aber, um nach einem Verbindungsabbruch die richtige Nachricht
            # zu wiederholen. Der Server merkt sich nichts davon; er reicht die
            # Kennung nur zurueck. Weggelassen werden darf sie weiterhin.
            msg_id = data.get("id")
            ref = {"id": msg_id} if isinstance(msg_id, str) else {}

            # isinstance vor dem Dekodieren: eine Zahl oder Liste an dieser
            # Stelle ist genauso "ungueltig" wie kaputtes base64, und b64d
            # soll nur Zeichenketten sehen.
            try:
                if not isinstance(raw_ct, str):
                    raise ValueError("ciphertext ist keine Zeichenkette")
                ciphertext = b64d(raw_ct)
            except ValueError:
                await ws.send_json({"type": "error", "reason": "ciphertext ungueltig", **ref})
                continue
            # WEITERGEREICHT WIRD AB HIER NUR NOCH DIESE FORM, nie raw_ct.
            # Siehe b64d: die Groessengrenze darunter gilt fuer die Bytes, und
            # nur was wirklich diese Bytes sind, darf in fremde Leitungen.
            ct_b64 = b64e(ciphertext)

            if not ciphertext or len(ciphertext) > MAX_CIPHERTEXT_BYTES:
                await ws.send_json({"type": "error", "reason": "ciphertext zu gross", **ref})
                continue
            try:
                # KANONISIEREN, nicht nur pruefen. decode_id nimmt Leerzeichen,
                # Bindestriche und Grossschreibung an, zugestellt wird danach
                # aber woertlich: connections.get(to) unten und recipient beim
                # INSERT. Ohne diese Zeile quittiert der Server eine
                # Schreibweise, die er nie zustellen kann.
                #
                # Eine Nicht-Zeichenkette ("to": 123) warf frueher in
                # decode_id AttributeError an .strip und riss die Verbindung
                # ab (proof_ws.py P4). Jetzt ist sie eine ungueltige Adresse.
                if not isinstance(to, str):
                    raise ValueError("Zieladresse ist keine Zeichenkette")
                to = encode_id(decode_id(to))
            except ValueError:
                await ws.send_json({"type": "error", "reason": "Zieladresse ungueltig", **ref})
                continue

            # Gibt es diese Adresse ueberhaupt, und was ist ihr KLEINSTES
            # Geraet? Ohne die erste Frage nimmt die Warteschlange 32
            # Zufallsbytes mit selbst gerechneter Pruefsumme genauso an wie
            # einen echten Empfaenger — und der Deckel darunter zaehlt je
            # Empfaenger, also nie mit. MIN() beantwortet beide Fragen in
            # EINER Abfrage: es ist NULL genau dann, wenn es keine Zeile gibt,
            # und laeuft ueber PRIMARY KEY (user_id, device_id).
            #
            # DAS MACHT KEIN VERZEICHNIS AUF: es gibt schon zwei, beide ohne
            # Anmeldung. GET /prekey/<adresse> antwortet 404 statt 200, und
            # /ws?user_id=<adresse> schickt sofort "erst /register aufrufen" —
            # letzteres voellig ungebremst. Wer Adressen durchprobiert, nimmt
            # den billigeren Weg. Hier zu schweigen kostete nur die
            # Ehrlichkeit des `ack`.
            kleinstes = db.execute(
                "SELECT MIN(device_id) FROM identities WHERE user_id=?",
                (to,)).fetchone()[0]
            if kleinstes is None:
                await ws.send_json(
                    {"type": "error", "reason": "Zieladresse unbekannt", **ref})
                continue

            # An WELCHES Geraet. Fehlt die Angabe, gilt das Geraet mit der
            # KLEINSTEN Kennung — genau die Zeile, aus der get_prekey seine
            # flachen Felder kopiert (`erstes = geraete[0]`, die Zeilen kommen
            # dort ORDER BY device_id). Beide Haelften des Rueckwaertspfads
            # muessen dasselbe Geraet meinen: fest 1 lieferte dem alten Client
            # die Schluessel von geraete[0] und schickte seine Nachricht an
            # Geraet 1 — ist das weggeraeumt (raeume_vergessene_geraete nach
            # GERAET_TTL, oder verdraengt beim vollen Geraetedeckel), bekommt
            # er dauerhaft "Zielgeraet unbekannt" und die Adresse ist fuer ihn
            # unerreichbar. Solange Geraet 1 lebt, IST MIN(device_id) die 1:
            # kleiner geht nicht, geraete_feld() laesst nur ab 1 zu.
            ziel_geraet = data.get("to_device")
            if ziel_geraet is None:
                ziel_geraet = kleinstes

            # Die Existenzfrage muss JE GERAET gestellt werden. Ohne sie
            # koennte ein Absender an Geraet 999 einer echten Adresse puffern,
            # das es nie gab -- und dieselbe Flut ueber eine Adresse fahren,
            # die die Existenzpruefung darueber besteht.
            if (not geraetekennung_moeglich(ziel_geraet)
                    or db.execute(
                        "SELECT 1 FROM identities WHERE user_id=? AND device_id=?",
                        (to, ziel_geraet)).fetchone() is None):
                await ws.send_json(
                    {"type": "error", "reason": "Zielgeraet unbekannt", **ref})
                continue

            target = connections.get(to, {}).get(ziel_geraet)

            # FLUECHTIG: nur an eine BESTEHENDE Verbindung, sonst nirgendwohin.
            # Keine Zeile in der Warteschlange, kein Anstoss, kein `q`. Das ist
            # fuer Dinge, die nur im Augenblick etwas bedeuten ("tippt gerade");
            # gepuffert kaemen sie an, wenn sie laengst falsch sind, und jede
            # einzelne weckte ein Telefon.
            #
            # Das `ack` kommt in beiden Faellen: der Absender soll nicht
            # erfahren, ob die Gegenstelle gerade verbunden ist. Sonst waere das
            # eine Anwesenheitsabfrage fuer jeden, der eine Adresse kennt.
            if data.get("fluechtig") is True:
                if not msg_limit_ok(user_id):
                    await ws.send_json(
                        {"type": "error", "reason": "zu viele Nachrichten",
                         "to": to, **ref})
                    continue
                if target is not None:
                    try:
                        await target.send_json({
                            "type": "message",
                            "from": user_id,
                            "from_device": device_id,
                            "ciphertext": ct_b64,
                            "ts": time.time(),
                        })
                    except Exception:
                        pass
                await ws.send_json({"type": "ack", "to": to, **ref})
                continue

            if target is not None and nachweisfaehig.get(to, {}).get(ziel_geraet):
                # ERST IN DIE WARTESCHLANGE, DANN LIVE SCHICKEN.
                #
                # Vorher ging eine live weitergereichte Nachricht ohne jede
                # Zeile hinaus, und `await target.send_json(...)` sagt nur,
                # dass der Rahmen im Schreibpuffer der ANDEREN Verbindung
                # liegt — nicht, dass er angekommen ist. Reisst deren Leitung
                # in diesem Moment, existiert die Nachricht danach nirgends
                # mehr, und der Absender hat sein `ack` bekommen.
                #
                # Das Fenster war ZEITLICH UNBEGRENZT: der Server bemerkt eine
                # still gestorbene Verbindung nie (kein Lebenszeichen, keine
                # Frist auf receive_json). Solange der tote Eintrag steht,
                # nimmt JEDER Absender an diese Adresse diesen Weg.
                # Nachgestellt am 27.07.2026 mit `transport.abort()`:
                # Absender bekam sein ack, die Warteschlange war leer, der
                # Empfaenger bekam beim Neuverbinden nichts.
                #
                # DER PREIS ist ein Schreib- und ein Loeschvorgang je
                # Nachricht auf dem heissen Weg, und QUEUE_MAX_PER_USER gilt
                # jetzt auch fuer verbundene Empfaenger. Beides ist zu
                # verkraften: ein verbundener Client bestaetigt in
                # Millisekunden, 500 unbestaetigte Nachrichten erreicht er
                # dabei nie. Eine verlorene Nachricht ist nicht zu verkraften.
                #
                # NUR fuer Gegenstellen, die den Nachweis beherrschen. Bei
                # einem alten Client bliebe die Zeile ewig liegen und seine
                # Warteschlange liefe voll — das waere schlimmer als der
                # Verlust, den es behebt. Der bekommt unveraendert den Weg
                # darunter.
                if not msg_limit_ok(user_id):
                    await ws.send_json(
                        {"type": "error", "reason": "zu viele Nachrichten",
                         "to": to, **ref})
                    continue
                # Alle Deckel (je Paar, je Absender, je Geraet, die ganze
                # Tabelle) an EINER Stelle — siehe schaffe_platz.
                if not schaffe_platz(to, ziel_geraet, user_id):
                    await ws.send_json(
                        {"type": "error", "reason": "Warteschlange voll",
                         "to": to, **ref})
                    continue

                with schreibsperre, db:
                    cur = db.execute(
                        "INSERT INTO queue (recipient, recipient_device, sender,"
                        " sender_device, ciphertext, ts) VALUES (?,?,?,?,?,?)",
                        (to, ziel_geraet, user_id, device_id, ciphertext,
                         time.time()),
                    )
                queue_zeilen_aendern(+1)
                zeile = cur.lastrowid

                # Das `q` ist der ganze Unterschied: damit weiss der
                # Empfaenger, WAS er bestaetigen soll. Ohne es koennte er die
                # Zeile nie loeschen lassen.
                #
                # GEFANGEN: die Leitung des EMPFAENGERS darf die des Absenders
                # nicht mitreissen. Frueher lief ein Fehler hier (Empfaenger
                # gerade weg) als Ausnahme aus diesem Handler heraus — der
                # Absender verlor seine Verbindung und sein `ack`, obwohl die
                # Nachricht sicher in der Warteschlange liegt und beim
                # naechsten Verbinden des Empfaengers zugestellt wird.
                try:
                    await target.send_json({
                        "type": "message",
                        "from": user_id,
                        # Die Kennung der ANGEMELDETEN VERBINDUNG des
                        # Absenders, nie ein Wert aus seinem Rahmen. Sonst
                        # koennte jeder behaupten, von einem beliebigen Geraet
                        # zu schreiben.
                        "from_device": device_id,
                        "ciphertext": ct_b64,
                        "ts": time.time(),
                        "q": zeile,
                    })
                except Exception:
                    pass
                # Das `ack` an den ABSENDER heisst weiterhin "der Server hat
                # sie" — und das stimmt jetzt auch, denn sie liegt auf der
                # Platte. Ein `ack` erst nach dem Nachweis des Empfaengers
                # waere etwas anderes (eine Zustellbestaetigung) und gehoert
                # nicht hierher.
                await ws.send_json({"type": "ack", "to": to, **ref})
                continue

            if target is not None:
                # Eine Gegenstelle OHNE Empfangsnachweis. Unveraendert der
                # alte Weg, mit allem, was daran haengt: kein "q", keine
                # Zeile, und bei einem Abriss in genau diesem Moment ist die
                # Nachricht weg. Schlechter als oben, aber besser als eine
                # Warteschlange, die sich bei ihr nie leert — sie kennt den
                # Nachweis ja nicht und wuerde ihn nie schicken.
                #
                # GEBREMST, aber mit dem eigenen Eimer (LIVE_CAPACITY) und
                # nicht mit msg_limit_ok — Begruendung dort.
                if not live_limit_ok(user_id):
                    await ws.send_json(
                        {"type": "error", "reason": "zu viele Nachrichten",
                         "to": to, **ref})
                    continue
                try:
                    await target.send_json({
                        "type": "message",
                        "from": user_id,
                        "from_device": device_id,
                        "ciphertext": ct_b64,
                        "ts": time.time(),
                    })
                except Exception:
                    # Die Leitung des Empfaengers ist tot, ihr Eintrag steht
                    # nur noch nicht abgeraeumt da. NICHT die des Absenders
                    # mitreissen (so war es bis zum 25.09.2026), sondern so
                    # tun, als waere der Empfaenger offline: weiter unten
                    # puffern. Dann kommt die Nachricht beim naechsten
                    # Verbinden an, statt verloren zu gehen.
                    target = None
                else:
                    await ws.send_json({"type": "ack", "to": to, **ref})
                    continue

            # Empfaenger offline -> puffern, aber gedeckelt.
            #
            # DIE BREMSE STEHT ERST HIER, nicht oben am Zweiganfang: nur dieser
            # Weg schreibt auf die Platte. Eine laufende Unterhaltung
            # (Empfaenger verbunden, der Zweig darueber) reicht nur durch und
            # bleibt unberuehrt.
            if not msg_limit_ok(user_id):
                await ws.send_json(
                    {"type": "error", "reason": "zu viele Nachrichten", "to": to, **ref})
                continue

            if not schaffe_platz(to, ziel_geraet, user_id):
                # Bewusst derselbe Wortlaut fuer jeden Deckel: der Absender
                # soll nichts Neues lernen muessen, und aeltere Clients kennen
                # diesen `reason` schon.
                await ws.send_json(
                    {"type": "error", "reason": "Warteschlange voll", "to": to, **ref})
                continue

            # Zwischen den Zaehlungen in schaffe_platz und diesem INSERT steht kein
            # await, und in `queue` schreibt sonst nur purge_expired — das
            # laeuft ebenfalls auf dem Event-Loop. Es kann sich also nichts
            # dazwischenschieben; die Sperre schuetzt hier gegen die Threads
            # der HTTP-Endpunkte, nicht gegen einen zweiten Absender.
            with schreibsperre, db:
                db.execute(
                    "INSERT INTO queue (recipient, recipient_device, sender,"
                    " sender_device, ciphertext, ts) VALUES (?,?,?,?,?,?)",
                    (to, ziel_geraet, user_id, device_id, ciphertext, time.time()),
                )
            # NACH dem with-Block: ein sqlite3.Error darin verlaesst die
            # Schleife ungefangen, dann darf der Zaehler nicht hochgelaufen
            # sein.
            queue_zeilen_aendern(+1)
            await ws.send_json({"type": "ack", "to": to, **ref})

            # Den Empfaenger anstossen, falls er das eingeschaltet hat.
            #
            # NICHT ABWARTEN: der Absender hat sein ack schon. Wenn der
            # Push-Server hakt, darf das seine Verbindung nicht aufhalten.
            stosse_im_hintergrund_an(to, ziel_geraet)

    except (WebSocketDisconnect, json.JSONDecodeError, RuntimeError):
        pass
    finally:
        if connections.get(user_id, {}).get(device_id) is ws:
            del connections[user_id][device_id]
            # Nur zusammen mit dem Eintrag, und nur wenn er UNS gehoert: hat
            # sich inzwischen eine neuere Verbindung DIESES GERAETS
            # eingetragen, wuerde ein Loeschen hier ihre Faehigkeit
            # wegnehmen — und der naechste Absender fiele fuer sie auf den
            # alten, verlustbehafteten Weg zurueck.
            #
            # Die Pruefung ist jetzt zweistufig, und beide Stufen sind noetig:
            # ohne `.get(device_id)` risse ein Geraet den Eintrag eines
            # ANDEREN Geraets derselben Adresse weg.
            nachweisfaehig.get(user_id, {}).pop(device_id, None)
            # Die leere Innentabelle abraeumen, sonst waechst `connections` um
            # einen Eintrag je Adresse, die sich je verbunden hat — dieselbe
            # Falle wie bei _buckets und _nonces.
            if not connections[user_id]:
                del connections[user_id]
                nachweisfaehig.pop(user_id, None)
