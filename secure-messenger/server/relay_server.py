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
OTK_MAX_JE_BUENDEL = int(os.getenv("BITDM_OTK_MAX", 200))
IDENTITAETEN_MAX = int(os.getenv("BITDM_IDENTITIES_MAX", 50_000))


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

# Wie viel der GANZE Relay pro Tag an Marken ausstellt, ueber alle Adressen.
#
# Die Menge je Adresse haelt einen Einzelnen auf, aber eine Adresse kostet
# nichts: mit vierzig Adressen waeren es 1 TiB am Tag, die Platte des Lagers
# (rund 940 GB frei) waere in einer Nacht voll. Das Lager weist dann zwar mit
# 507 ab (MIN_FREI_BYTES), aber ab da fuer ALLE bis zur Kehrmaschine.
#
# DER PREIS ist bekannt: diese Grenze ist eine Abschaltung fuer alle, sobald
# jemand sie ausschoepft — genau das, was docs/ZWISCHENLAGER.md gegen eine
# globale Grenze einwendet. Deshalb steht sie hoch: 200 GiB am Tag lassen
# der vollen Platte mindestens vier Tage, und der Storage-Waechter meldet
# schon bei 80 GB frei. Sie begrenzt die GESCHWINDIGKEIT, mit der sich die
# Platte fuellen laesst, nicht den ehrlichen Betrieb.
BLOB_TAGESMENGE_GESAMT = int(os.getenv("BITDM_BLOB_QUOTA_TOTAL", 200 * 1024**3))

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
    seit = time.time() - 24 * 3600
    return db.execute(
        "SELECT COALESCE(SUM(groesse), 0) FROM blob_marken WHERE user_id=? AND ts > ?",
        (user_id, seit),
    ).fetchone()[0]


def blob_menge_heute_gesamt() -> int:
    """Was der ganze Relay in den letzten 24 Stunden ausgestellt hat."""
    seit = time.time() - 24 * 3600
    return db.execute(
        "SELECT COALESCE(SUM(groesse), 0) FROM blob_marken WHERE ts > ?",
        (seit,),
    ).fetchone()[0]


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
    # Fuer die Tagesmenge des ganzen Relays (blob_menge_heute_gesamt). Der
    # bestehende Index beginnt mit user_id und hilft dort nicht.
    conn.execute("CREATE INDEX IF NOT EXISTS idx_blob_marken_ts "
                 "ON blob_marken(ts)")

    conn.commit()
    wandere_auf_geraete(conn)
    return conn


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


def loesche_geraet(uid: str, geraet: int) -> int:
    """Eine Geraetezeile samt ihrer Post entfernen. Rueckgabe: geloeschte Zeilen.

    Die Einmalschluessel nimmt die Kaskade. Die Warteschlange NICHT — sie
    zeigt auf keine Geraetezeile und wuerde sonst als Post an ein Geraet
    liegenbleiben, das es nicht mehr gibt, bis QUEUE_TTL_SECONDS sie holt.

    Ruft NUR auf, wer die schreibsperre schon haelt.
    """
    cur = db.execute("DELETE FROM queue WHERE recipient=? AND recipient_device=?",
                     (uid, geraet))
    weg = cur.rowcount
    db.execute("DELETE FROM identities WHERE user_id=? AND device_id=?",
               (uid, geraet))
    return weg


def raeume_vergessene_geraete() -> int:
    """Geraete ohne Lebenszeichen seit GERAET_TTL entfernen. Rueckgabe: Anzahl.

    Ein Geraet, das nie wieder kommt, heilte frueher allein durch
    QUEUE_TTL_SECONDS. Das reicht nicht mehr: solange seine Zeile lebt, hat es
    eine eigene Warteschlange, die dauerhaft am Deckel steht — und ab da faellt
    fuer jeden Absender an dieses Geraet die aelteste Zeile weg. Ein totes
    Telefon macht die Adresse damit teilweise unbeschickbar.
    """
    cutoff = time.time() - GERAET_TTL
    entfernte_zeilen = 0
    with schreibsperre, db:
        tot = db.execute(
            f"SELECT user_id, device_id FROM identities WHERE {LEBENSZEICHEN} < ?",
            (cutoff,),
        ).fetchall()
        for uid, geraet in tot:
            entfernte_zeilen += loesche_geraet(uid, geraet)
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
        db.execute("DELETE FROM blob_marken WHERE ts < ?", (time.time() - 24 * 3600,))
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

    Der Dienst lauscht ausschliesslich auf 127.0.0.1 und haengt hinter nginx;
    X-Forwarded-For stammt daher aus vertrauenswuerdiger Quelle.
    """
    fwd = request.headers.get("x-forwarded-for")
    if fwd:
        return fwd.split(",")[0].strip()
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


def limit_schluessel(request: Request) -> str | None:
    """Wonach die Bremse je Herkunft zaehlt — oder None fuer "gar nicht".

    IPv6 JE /64. Ein Anschluss bekommt vom Anbieter mindestens ein /64,
    meist ein /56 oder /48; jede einzelne Adresse darin ist frei waehlbar.
    Je voller Adresse gezaehlt hatte ein Angreifer damit 2**64 frische
    Eimer — die Bremse war fuer IPv6 praktisch abgeschaltet und fuellte
    obendrein _buckets. Ein /64 ist die kleinste Einheit, die ein Anschluss
    nicht beliebig vervielfachen kann.

    ONION: None. Ueber Tor kommen ALLE von 127.0.0.1, eine Bremse je IP waere
    dort eine einzige gemeinsame Bremse fuer alle Tor-Nutzer — ein Stoerer
    sperrte damit alle anderen aus. Stattdessen greifen dort die Grenzen je
    Adresse (otk_limit_ok, msg_limit_ok, NONCE_PLAETZE), die Grenzen im
    Onion-vHost (limit_req/limit_conn), das Speicherdach (SPEICHER_MAX) und
    die Grenzen in tor selbst (HiddenServiceMaxStreams).
    """
    if kommt_ueber_onion(request):
        return None
    ip = client_ip(request)
    try:
        adresse = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    if adresse.version == 6:
        if adresse.ipv4_mapped is not None:
            return str(adresse.ipv4_mapped)
        return str(ipaddress.ip_network(f"{adresse}/64", strict=False))
    return str(adresse)


def herkunft_ok(request: Request, familie: str, cost: float = 1.0) -> bool:
    """Die Bremse je Herkunft fuer einen HTTP-Endpunkt. Onion: immer ja."""
    schluessel = limit_schluessel(request)
    if schluessel is None:
        return True
    return rate_limit_ok(f"{familie}:{schluessel}", cost)


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
_nonces: dict[tuple[str, int | None], list[tuple[bytes, float]]] = {}
# Wie viele Nonces insgesamt in _nonces stehen — mitgefuehrt, damit das Dach
# nicht bei jeder Anfrage ueber alle Listen zaehlen muss.
_nonce_zahl = 0


class Ueberlastet(Exception):
    """Der Speicherdeckel ist erreicht; die Anfrage bekommt 503."""


def issue_nonce(user_id: str, device_id: int | None = None) -> bytes:
    global _nonce_zahl
    nonce = secrets.token_bytes(32)
    with _speichersperre:
        jetzt = time.monotonic()
        _vielleicht_aufraeumen(jetzt)
        schluessel = (user_id, device_id)
        alt = _nonces.get(schluessel, [])
        offen = [e for e in alt if e[1] > jetzt]
        _nonce_zahl -= len(alt) - len(offen)
        # Nur ein NEUES Paar scheitert am Dach. Ein Paar, das schon da ist,
        # tauscht hoechstens ein altes Nonce gegen ein neues und belegt damit
        # nichts dazu.
        if len(offen) < NONCE_PLAETZE and _nonce_zahl >= SPEICHER_MAX:
            if offen:
                _nonces[schluessel] = offen
            else:
                _nonces.pop(schluessel, None)
            raise Ueberlastet()
        # Voll: das AELTESTE faellt, nicht das neue. Das neue gehoert zu der
        # Anfrage, die gerade laeuft — ein ehrlicher Client schickt gleich
        # darauf sein /register.
        while len(offen) >= NONCE_PLAETZE:
            offen.pop(0)
            _nonce_zahl -= 1
        offen.append((nonce, jetzt + NONCE_TTL_SECONDS))
        _nonce_zahl += 1
        _nonces[schluessel] = offen
    return nonce


def offene_nonces(user_id: str, device_id: int | None = None) -> list[bytes]:
    """Die noch gueltigen Nonces dieses Paares, OHNE sie zu verbrauchen."""
    jetzt = time.monotonic()
    with _speichersperre:
        return [n for n, ablauf in _nonces.get((user_id, device_id), [])
                if ablauf > jetzt]


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
        for i, (n, ablauf) in enumerate(liste):
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


GERAET_MAX_KENNUNG = 2**31 - 1


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
        return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()


class RegisterRequest(BaseModel):
    bundle: PreKeyBundle
    signature: str                        # base64, XEdDSA ueber nonce||sha256(bundle)


class ChallengeRequest(BaseModel):
    user_id: str
    # Muss zur device_id im spaeteren /register passen, sonst findet der
    # Besitznachweis sein Nonce nicht — siehe _nonces.
    device_id: int | None = geraete_feld()


# --------------------------------------------------------------------------- #
#  App
# --------------------------------------------------------------------------- #

@asynccontextmanager
async def lifespan(app: FastAPI):
    global db
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

    async def janitor():
        while True:
            await asyncio.sleep(3600)
            try:
                purge_expired()
                vergessen = raeume_vergessene_geraete()
                if vergessen:
                    print(f"[i] {vergessen} vergessene Geraete entfernt")
                queue_zeilen_neu_zaehlen()
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
        nonce = issue_nonce(req.user_id, req.device_id)
    except Ueberlastet as exc:
        raise HTTPException(503, "Relay ueberlastet, bitte spaeter erneut") from exc
    return {"nonce": b64e(nonce)}


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

    try:
        signature = b64d(req.signature)
    except Exception as exc:
        raise HTTPException(400, "signature ist kein gueltiges base64") from exc

    # Das Nonce haengt am (Adresse, Geraet)-Paar. Ein Geraet kann sich damit
    # nicht mit dem Nonce eines anderen anmelden, und zwei Geraete derselben
    # Adresse nehmen sich ihre Nonces nicht mehr gegenseitig weg.
    #
    # Der Client schickt sein Nonce nicht mit (so ist er ausgeliefert, 1.6 bis
    # 1.8). Also wird die Signatur gegen JEDES offene Nonce des Paares
    # geprueft, und verbraucht wird nur das, zu dem sie passt — siehe
    # verbrauche_nonce, warum erst danach.
    kandidaten = offene_nonces(bundle.user_id, bundle.device_id)
    if not kandidaten:
        raise HTTPException(401, "kein gueltiges Nonce — erst /register/challenge")

    inhalt = hashlib.sha256(bundle.canonical_bytes()).digest()
    treffer = next((n for n in kandidaten
                    if verify_signature(identity_key, n + inhalt, signature)), None)
    if treffer is None:
        raise HTTPException(403, "Besitznachweis fehlgeschlagen")
    if not verbrauche_nonce(bundle.user_id, bundle.device_id, treffer):
        # Zwischen Pruefen und Verbrauchen hat ein gleichzeitiger Aufruf mit
        # derselben Signatur das Nonce genommen (oder es ist gerade
        # abgelaufen). Genau einmal heisst genau einmal.
        raise HTTPException(401, "kein gueltiges Nonce — erst /register/challenge")

    # Die Sperre liegt eine Ebene ueber `with db:` und bleibt bis hinter den
    # COUNT offen. Sonst zaehlte die Antwort einen Stand, den inzwischen ein
    # anderer Aufrufer veraendert haben kann — und der Client leitet aus dieser
    # Zahl ab, ob er Prekeys nachliefern muss.
    # Fehlt die Kennung, ist es Geraet 1 — die Regel fuer den ganzen Umbau.
    geraet = 1 if bundle.device_id is None else bundle.device_id

    with schreibsperre:
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
                raise HTTPException(507, "Dieser Relay nimmt keine neuen "
                                         "Adressen mehr auf")

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
                weg = loesche_geraet(bundle.user_id, totes[0])
            queue_zeilen_aendern(-weg)

        try:
            with db:
                db.execute(
                    "INSERT INTO identities (user_id, device_id, identity_key,"
                    " registration_id, signed_prekey_id, signed_prekey,"
                    " signed_prekey_sig, updated_at)"
                    " VALUES (?,?,?,?,?,?,?,?)"
                    " ON CONFLICT(user_id, device_id) DO UPDATE SET"
                    " identity_key=excluded.identity_key,"
                    " registration_id=excluded.registration_id,"
                    " signed_prekey_id=excluded.signed_prekey_id,"
                    " signed_prekey=excluded.signed_prekey,"
                    " signed_prekey_sig=excluded.signed_prekey_sig,"
                    " updated_at=excluded.updated_at",
                    (bundle.user_id, geraet, identity_key, bundle.registration_id,
                     bundle.signed_prekey_id, signed_prekey,
                     signed_prekey_sig, time.time()),
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

        # Zaehlt JE GERAET. Der Client leitet aus dieser Zahl ab, ob er
        # nachliefern muss — adressweit gezaehlt saehe ein leeres Zweitgeraet
        # den vollen Vorrat des Erstgeraets und lieferte nie nach.
        count = db.execute(
            "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=? AND device_id=?",
            (bundle.user_id, geraet),
        ).fetchone()[0]
    return {"ok": True, "one_time_prekeys": count}


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
    """
    if not herkunft_ok(request, "pk"):
        raise HTTPException(429, "zu viele Anfragen")

    # Der SELECT gehoert in dieselbe Sperre wie das DELETE darunter, damit das
    # ausgelieferte Bundle aus EINEM Zustand stammt: davor konnte er die noch
    # nicht committete Identitaet eines anderen Threads sehen.
    with schreibsperre:
        rows = db.execute(
            "SELECT device_id, identity_key, signed_prekey_id, signed_prekey,"
            " signed_prekey_sig, registration_id FROM identities"
            " WHERE user_id=? ORDER BY device_id", (user_id,)
        ).fetchall()
        if not rows:
            raise HTTPException(404, "unbekannte Adresse")

        if nur_geraete:
            return {
                "user_id": user_id,
                "geraete": [{"device_id": r[0], "registration_id": r[5]}
                            for r in rows],
            }

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
        otks: dict[int, tuple] = {}
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

    def als_geraet(r) -> dict:
        otk = otks.get(r[0])
        return {
            "device_id": r[0],
            "registration_id": r[5],
            "signed_prekey_id": r[2],
            "signed_prekey": b64e(r[3]),
            "signed_prekey_sig": b64e(r[4]),
            "one_time_prekey": (
                {"key_id": otk[0], "public_key": b64e(otk[1])} if otk else None
            ),
        }

    geraete = [als_geraet(r) for r in rows]
    erstes = geraete[0]
    return {
        "user_id": user_id,
        # Der Identitaetsschluessel gehoert der ADRESSE, nicht dem Geraet — er
        # steht deshalb nur einmal da und nicht in jedem Geraeteeintrag.
        "identity_key": b64e(rows[0][1]),
        "registration_id": erstes["registration_id"],
        "signed_prekey_id": erstes["signed_prekey_id"],
        "signed_prekey": erstes["signed_prekey"],
        "signed_prekey_sig": erstes["signed_prekey_sig"],
        "one_time_prekey": erstes["one_time_prekey"],
        "geraete": geraete,
    }


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
    # UnifiedPush-Themen heissen "up" + Zufallszeichen. Alles andere waere
    # kein Anstoss-Endpunkt, sondern irgendein Pfad auf dem Push-Server.
    return re.fullmatch(r"/up[A-Za-z0-9_-]+", teile.path) is not None


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
        async with httpx.AsyncClient(timeout=PUSH_TIMEOUT) as client:
            # NICHT follow_redirects=True. httpx folgt ab Werk nicht; ein
            # Umzug wuerde den POST sonst an einen beliebigen Host tragen und
            # den Host-Pin aus PUSH_ERLAUBTE_HOSTS aushebeln.
            antwort = await client.post(anstoss_ziel(row[0]), content=b"")
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
    await ws.send_json({"type": "challenge", "nonce": b64e(nonce)})
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
    erwartet = nonce if roh_geraet is None else nonce + device_id.to_bytes(4, "big")

    if not verify_signature(identity_key, erwartet, signature):
        await ws.send_json({"type": "auth_result", "ok": False})
        await ws.close(code=4403)
        return None
    return user_id, device_id, reply


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
    user_id, device_id, reply = angemeldet

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
    await ws.send_json({"type": "auth_result", "ok": True,
                        "empfangsnachweis": nachweis, "device_id": device_id,
                        "fluechtig": True})

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
        otk_left = db.execute(
            "SELECT COUNT(*) FROM one_time_prekeys WHERE user_id=? AND device_id=?",
            (user_id, device_id)
        ).fetchone()[0]
        if otk_left < OTK_LOW_WATERMARK:
            await ws.send_json({"type": "prekeys_low", "remaining": otk_left})

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
                verbraucht = blob_menge_heute(user_id)
                if verbraucht + groesse > BLOB_TAGESMENGE:
                    await ws.send_json({
                        "type": "error",
                        "reason": "Tagesmenge erschoepft",
                        "frei": max(0, BLOB_TAGESMENGE - verbraucht),
                        **marken_ref,
                    })
                    continue
                # Und die Menge des GANZEN Relays, siehe BLOB_TAGESMENGE_GESAMT.
                # Eigener Wortlaut: "Tagesmenge erschoepft" hiesse fuer den
                # Nutzer "du warst es", und das stimmt hier nicht. Aeltere
                # Clients zeigen den Text einfach an.
                gesamt = blob_menge_heute_gesamt()
                if gesamt + groesse > BLOB_TAGESMENGE_GESAMT:
                    await ws.send_json({
                        "type": "error",
                        "reason": "Zwischenlager fuer heute ausgelastet",
                        "frei": 0,
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
                    db.execute(
                        "INSERT INTO blob_marken (user_id, groesse, ts) VALUES (?,?,?)",
                        (user_id, groesse, time.time()),
                    )
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
            asyncio.create_task(stosse_an(to, ziel_geraet))

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
