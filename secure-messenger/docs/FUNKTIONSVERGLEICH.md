# Funktionsvergleich — BitDM neben Signal, SimpleX, Session, Briar, Threema, Cwtch

Stand 25.09.2026. Aufgeschrieben, nachdem die Funktionen der vergleichbaren
Messenger recherchiert und die fehlenden in BitDM eingebaut wurden. Jede
Zeile mit ✅ ist gebaut UND durch Tests belegt; die Testdatei steht dabei.

## Was die anderen haben — und was BitDM jetzt hat

| Funktion | Vorbild | BitDM | Belegt durch |
|---|---|---|---|
| Antworten mit Zitat | Signal, alle | ✅ nur die Kennung reist, das Zitat kommt aus dem eigenen Verlauf | `test/net/nachrichten_funktionen_test.dart` |
| Reaktionen | Signal | ✅ eine je Person, neuere ersetzt ältere | `test/store/nachrichten_regeln_test.dart` |
| Bearbeiten | Signal (24 h, 10×) | ✅ dieselben Grenzen, nur eigene Texte | dito, 4 Mutationsproben |
| Für alle löschen | Signal (24 h) | ✅ Leerstelle statt Loch, Anhang und Reaktionen fallen mit | dito |
| Für mich löschen | alle | ✅ | dito |
| Selbstlöschende Nachrichten je Chat | Signal, SimpleX | ✅ zusätzlich zur Grundeinstellung | `nachrichten_funktionen_test` |
| Tipp-Anzeige | Signal | ✅ ab Werk aus, flüchtig über den Relay | `test/net/tippen_test.dart` |
| Textformatierung, Spoiler | Signal | ✅ `*fett* _kursiv_ ~durch~ \`fest\` \|\|Spoiler\|\|` | `test/oberflaeche/formatierung_test.dart` |
| Angeheftete Nachrichten | Signal (Jan. 2026) | ✅ höchstens drei je Chat | `nachrichten_regeln_test` |
| Geplante Nachrichten | Signal | ✅ übersteht Neustarts | `nachrichten_funktionen_test` |
| Umfragen | Signal, Threema | ✅ Einzel- und Mehrfachwahl | `nachrichten_regeln_test`, `nachrichten_funktionen_test` |
| Sprachnachrichten | alle | ✅ Android; über den verschlüsselten Anhang-Weg | `test/oberflaeche/sprachnachricht_test.dart` |
| Gruppen | alle | ✅ bis 20 Mitglieder, Fanout über Zweiersitzungen | `test/net/gruppen_test.dart` |
| Notiz an mich | Signal | ✅ mit Spiegel auf die eigenen Geräte | `test/net/zwei_geraete_test.dart` |
| Anheften, Archiv, Stumm | Signal | ✅ nur örtlich | `test/oberflaeche/chatliste_ordnung_test.dart` |
| Suche | alle | ✅ nur örtlich | `nachrichten_regeln_test` |
| Verschlüsselte Sicherung | Signal, Threema | ✅ Verlauf ohne Schlüssel, geht nur mit den 12 Wörtern auf | `test/net/sicherung_test.dart` |
| Panik-/Selbstzerstörungs-Passwort | SimpleX | ✅ von außen nicht von einem echten Passwort zu unterscheiden | `test/lock/panik_passwort_test.dart` |
| Inkognito-Tastatur | Signal, Threema | ✅ immer, ohne Schalter | — |
| Keine Telefonnummer | Session, SimpleX, Threema, Briar | ✅ war schon da | — |
| Offline über Bluetooth | Briar | ✅ war schon da (`docs/NAHBEREICH.md`) | — |
| Sicherheitsnummer, QR-Prüfung | Signal, Threema | ✅ war schon da | — |
| Bildschirmschutz | Signal | ✅ war schon da | — |
| Eigener Server | SimpleX | ✅ war schon da (`install.sh`) | — |

### Zweite Runde (1.7.0, 25.09.2026)

| Funktion | Vorbild | BitDM | Belegt durch |
|---|---|---|---|
| Bild-Metadaten entfernen (GPS, Kamera, Zeit), neutrale Bildnamen | Signal, SimpleX 6.3 | ✅ JPEG, PNG, WebP ohne Neukodierung; die Drehung bleibt | `test/anhang/metadaten_test.dart` (echte Bilder, geöffnet nach dem Entfernen) |
| Markierte Nachrichten (★) | Threema | ✅ nur örtlich, eigener Filter | `test/oberflaeche/chatliste_ordnung_test.dart`, `test/core/haken_test.dart` |
| Filter der Chatliste | Signal (Chat-Ordner) | ✅ Alle · Ungelesen · Gruppen · ★ | `chatliste_ordnung_test` |
| Quittungen zufällig verzögert | Forschung: Martiny u. a., NDSS 2021 | ✅ 0,3–2,5 s, gegen Zuordnung über die Zeit | `test/core/haken_test.dart` |
| Schlüsselbild (Randomart) | OpenSSH | ✅ in Einstellungen, „Meine ID“ und im Verschlüsselungsblatt | `test/oberflaeche/schluesselbild_test.dart` |
| Befehle in der Schreibzeile (`/timer`, `/verify`, `/poll`, `/theme`, `/shrug`) | Terminal, Slack | ✅ unbekannte gehen als Text | `test/oberflaeche/befehle_test.dart` |
| Themen, auch Material (You) | Signal, Material 3 | ✅ neun Themen, langsamer Chiffre-Übergang, wanderndes Thema, Akzentfarbe des Systems ab Android 12 | `test/oberflaeche/themen_test.dart` |
| Entschlüsseln-Effekt an neuen Nachrichten | — | ✅ abschaltbar, respektiert „Bewegung reduzieren“ | `themen_test` |
| Sprache und Aussehen merken | alle | ✅ vorher bei jedem Start vergessen | `test/core/preferences_test.dart` |

### Dritte Runde (1.8.0, 25.09.2026)

| Funktion | Vorbild | BitDM | Belegt durch |
|---|---|---|---|
| Echte Ungelesen-Zahl | alle | ✅ je Unterhaltung, Nachrichten in die offene Unterhaltung gelten sofort als gelesen | `test/oberflaeche/chatliste_ordnung_test.dart`, `test/store/encrypted_database_test.dart` |
| Ruhezeiten | Signal (Benachrichtigungsprofile) | ✅ Fenster auch über Mitternacht, angeheftete Chats kommen durch | `test/core/ruhezeit_test.dart` |
| Wiederherstellung über Vertrauenskontakte | Briar/Dark Crystal | ✅ Shamir über GF(256), 2/3, 3/5, 4/7; Teile mit Prüfsumme | `test/crypto/teilgeheimnis_test.dart`, `test/oberflaeche/vertrauen_test.dart` |
| Fernlöschung durch Vertrauenskontakte | Briar-Prototyp | ✅ k von n, 24 h, 10 min Countdown mit Abbrechen | `test/core/fernloeschung_test.dart`, `test/net/gruppen_test.dart`, `test/oberflaeche/fernloeschung_ui_test.dart` |
| Einmal-Ansicht | Signal | ✅ Fotos und Sprachnachrichten, erzwungene Bildschirmsperre, nicht in der Sicherung | `test/net/anhang_end_to_end_test.dart` |
| Bilder in der Blase | alle | ✅ nach dem Holen, Antippen zeigt groß | — |
| Verteilerlisten | Threema | ✅ einzeln verschickt, nur örtlich | `chatliste_ordnung_test`, `test/core/haken_test.dart` |
| Erwähnungen in Gruppen | SimpleX 6.3 | ✅ `@XLLW…S7JD`, kommen durch Stumm und Ruhezeit | `test/oberflaeche/erwaehnung_test.dart` |
| Zustellhaken je Mitglied | Signal | ✅ zwei Haken erst, wenn alle sie haben | `test/net/gruppen_test.dart` |
| Notizen: Bearbeiten/Löschen auf alle Geräte | Signal | ✅ | `test/net/zwei_geraete_test.dart` |
| Sicherung mit Anhangdateien | Signal | ✅ wahlweise, bis 100 MB | `anhang_end_to_end_test` |
| Metadaten auch aus HEIC/AVIF/Video | Signal | ✅ ohne Verschieben der Daten | `test/anhang/metadaten_test.dart` |
| Tor (SOCKS5/Orbot) und Relay als Onion-Dienst | Molly, Cwtch | ✅ kein DNS-Leck, TLS über dem Tunnel | `test/net/netzweg_test.dart` |
| Tarnverkehr | Loopix (Forschung) | ✅ wahlweise, gegen Beobachter der Leitung | `server/test_relay.py` |

## Was bewusst NICHT gebaut wurde — und warum

| Funktion | Vorbild | Warum nicht |
|---|---|---|
| Sender Keys für Gruppen | Signal (seit 2021) | Sie sind eine Maßnahme für **Effizienz** in großen Gruppen, keine für Sicherheit — und haben sogar die schwächere Erholung nach einem Einbruch ins Gerät. Bei höchstens 20 Mitgliedern ist die Verteilung über die Zweiersitzungen (wie bei Session und SimpleX) die bessere Wahl. Der eigentliche Gewinn — ein Upload statt zwanzig — bräuchte außerdem einen Relay mit Mehrfachzustellung. |
| Linkvorschau | Signal, WhatsApp | Die Vorschau lädt die Seite — also erfährt der fremde Server, dass und wann jemand den Link bekommen hat. Das widerspricht dem Grund, warum es BitDM gibt. |
| Anzeigenamen/Spitznamen | alle | Die App sagt ausdrücklich „Namen gibt es nicht — auch nicht lokal“ (`noNames`). Das ist eine Produktentscheidung, keine Lücke. |
| Anrufe (Sprache, Video) | Signal, Session, Threema | Braucht WebRTC und TURN-Server, die Metadaten sehen. Ein eigenes Vorhaben mit eigener Bedrohungsanalyse. |
| Onion-Routing / Tor | Session, Briar, Cwtch | Der Relay sieht heute die IP-Adresse. Tor wäre der Weg dagegen; das ist eine Netzschicht, kein Menüpunkt. Offen. |
| Post-Quanten-Schlüsseltausch (PQXDH) | Signal, SimpleX | `libsignal_protocol_dart` 0.8.2 kennt kein Kyber. Hängt an der Bibliothek. |
| Keine dauerhafte Kennung | SimpleX | Bei BitDM IST die Adresse der Schlüssel — der Kern des Entwurfs. |
| Storys, Sticker, Zahlungen | Signal | Kein Messenger-Kern; jede davon vergrößert die Angriffsfläche. |
| Gruppen über 20 | Signal (1000) | Ohne Sender-Keys kostet jede Nachricht einen Umschlag je Mitglied und Gerät; die Relay-Bremse (180 im Schub, 6/s) setzt die Grenze. Sender-Keys wären der Ausbau. |
| Verborgene Chats | Threema | Nicht gebaut. Das Panik-Passwort deckt den Zwangsfall ab. |

## Bekannte Grenzen des Gebauten

- **Gruppen:** Der Admin ändert die Mitglieder; tritt er aus, rückt das
  nächste Mitglied nach (`Gruppe.nachfolger`, Test „GEHT DER ADMIN, RUECKT DER
  NAECHSTE NACH“). Neue Mitglieder sehen den Verlauf vor ihrem Beitritt nicht
  (wie bei Signal). Zustellhaken je Mitglied seit 25.09.2026, Lesehaken in
  Gruppen bewusst nicht. Noch keine Sender Keys: jede Nachricht geht einzeln
  über die Zweiersitzung an jedes Mitglied.
- **Einladungen nur von Kontakten:** Die Regel in `_nimmGruppenStand` schützt
  gegen einen *veränderten* Client ohne alte Sitzung. Der vorhandene Test
  bleibt auch ohne sie grün, weil beim Entfernen eines Kontakts die Sitzung
  mitgeht — die Regel selbst ist über die Schnittstelle des echten Kerns
  nicht erreichbar (Kommentar in `gruppen_test.dart`).
- **Notizen:** Bearbeiten, Reaktionen und Löschen in den Notizen bleiben auf
  dem Gerät, auf dem sie passieren; nur neue Notizen werden gespiegelt.
- **Sprachnachrichten:** nur Android. Das Manifest trägt dafür wieder
  `RECORD_AUDIO` (vorher ausdrücklich entfernt) — Begründung dort.
- **Tipp-Anzeige:** braucht einen Relay mit flüchtigen Rahmen (ab dieser
  Fassung von `relay_server.py`). Gegen einen alten Relay sendet der Client
  keine, statt dass sie gepuffert werden und Telefone wecken.
- **Sicherung:** Anhänge selbst sind nicht enthalten, nur ihre Anleitungen —
  holbar, solange sie im Zwischenlager liegen (14 Tage).
- **Metadaten:** HEIC, Videos und Dokumente gehen unverändert hinaus — nur
  JPEG, PNG und WebP werden bereinigt.
- **Themen:** vor dem Entsperren gilt Nocturne; das gewählte Thema liegt in der
  verschlüsselten Datenbank und wird danach langsam eingeblendet.
- **Alle neuen Nutzlast-Arten (9–18):** eine ältere App-Fassung verwirft sie
  still. Sie sieht also keine Reaktionen, Umfragen oder Gruppen, stürzt aber
  auch nicht ab.

## Quellen der Recherche

- Zweite Runde: [Signal View-once](https://support.signal.org/hc/en-us/articles/360038443071-View-Once-Media),
  [SimpleX 6.3](https://simplex.chat/blog/20250308-simplex-chat-v6-3-new-user-experience-safety-in-public-groups.html),
  [Threema Features](https://threema.com/en/faq/features),
  [Improving Signal's Sealed Sender (NDSS 2021)](https://www.researchgate.net/publication/350050666_Improving_Signal's_Sealed_Sender),
  [The drunken bishop](http://dirk-loss.de/sshvis/drunken_bishop.pdf)

- Signal: [Message Reactions](https://support.signal.org/hc/en-us/articles/360039929972-Message-Reactions),
  [Edit Message](https://support.signal.org/hc/en-us/articles/6255134251546-Edit-Message),
  [Delete for everyone](https://support.signal.org/hc/en-us/articles/360050426432-Delete-for-everyone),
  [Disappearing messages](https://support.signal.org/hc/en-us/articles/360007320771-Set-and-manage-disappearing-messages),
  [Pinned messages](https://alternativeto.net/news/2026/1/signal-now-lets-users-pin-messages-in-one-on-one-and-group-chats-with-time-limits),
  [Scheduled messages](https://alternativeto.net/news/2023/7/signal-introduces-new-message-scheduling-feature/)
- Vergleiche: [Secure Messaging July 2026](https://stateofsurveillance.org/guides/basic/secure-messaging-comparison/),
  [Briar vs. Session vs. SimpleX](https://sourceforge.net/software/compare/Briar-vs-Session-vs-SimpleX-Chat/),
  [SecuChart](https://bkil.gitlab.io/secuchart/),
  [Alternatives to Session](https://vsx.global/alternatives-to-session-simplex-cwtch-briar-and-other-messengers-that-protect-metadata/)
- Session: [Wikipedia](https://en.wikipedia.org/wiki/Session_(software)),
  [Finanzierungskrise 2026](https://alternativeto.net/news/2026/4/encrypted-messaging-app-session-will-shut-down-in-90-days-unless-new-funding-are-secured/)
