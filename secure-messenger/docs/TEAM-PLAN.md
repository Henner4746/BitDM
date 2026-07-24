> ## ⚠️ Historisches Dokument — überholt seit 2026-07-25
>
> Dieses Dokument beschreibt die ursprüngliche Aufteilung zwischen zwei Personen.
> **Person A (Lennard) hat das Projekt verlassen**, nachdem die UI-Gestaltung fertig war.
> Die hier beschriebene Rollentrennung gilt nicht mehr, und das Interface ist
> **nicht mehr eingefroren**.
>
> **Maßgeblich ist jetzt [`../../PLAN.md`](../../PLAN.md).**
>
> Der wichtigste Irrtum hier: Milestone M2 verspricht, es werde „nur **eine
> Zeile** getauscht". Das ist **widerlegt** — `main.dart`, `data.dart` und
> `painters.dart` enthalten keine einzige Referenz auf `MessengerCore`. Die
> Trennung wurde dokumentiert, aber nie verdrahtet; die gesamte Zustandsschicht
> fehlt. Siehe PLAN.md §6.
>
> Aufgehoben bleibt das Dokument, weil es die ursprüngliche Absicht festhält und
> erklärt, warum der Code so aussieht, wie er aussieht.

# Arbeitsaufteilung — Secure Messenger (2 Personen)

Ziel: Zwei Leute arbeiten **gleichzeitig**, ohne sich zu blockieren. Möglich wird
das durch **eine klare Trennlinie**: die Schnittstelle `MessengerCore`.

- **Person A** baut die App drüber (GUI ruft die Schnittstelle nur auf).
- **Person B** baut die Krypto/Backend drunter (implementiert die Schnittstelle).

Solange beide sich an den Vertrag halten, ist es egal, wie weit die andere Seite ist.

```mermaid
flowchart TB
  subgraph A["👤 Person A — App / GUI / Design"]
    UI["Screens · Widgets · Design · State-Management"]
  end
  subgraph IF["🤝 Schnittstelle: MessengerCore (Dart-Interface)"]
    I["initIdentity() · myId · addContact() · sendMessage() · incomingMessages …"]
  end
  subgraph B["👤 Person B — Krypto / Security / Backend"]
    CORE["libsignal · X3DH · Double Ratchet · Key-Storage"]
    WS["WebSocket-Client"]
    SRV["Python Relay-Server (VPS)"]
  end
  UI -->|ruft auf| I
  I -->|implementiert von| CORE
  CORE --- WS
  WS <-->|nur verschlüsselt| SRV
```

---

## 👤 Person A — App, Design, GUI  *(Lennard)*

**Du besitzt alles, was der Nutzer sieht und anfasst.** Du arbeitest gegen die
Schnittstelle und benutzt beim Entwickeln die **`MockMessengerCore`** (liefert
Fake-Daten + Fake-Antworten) — so läuft deine App sofort, ganz ohne Krypto.

**Aufgaben / Screens:**
- [ ] Flutter-Projekt-Setup, Navigation, Theme (Dark Mode, Farben, Typografie → cleanes Design)
- [ ] **Onboarding**: „Willkommen", Identität erzeugen (`initIdentity()`), kurze Erklärung
- [ ] **Meine ID**: eigene „lange Nummer" anzeigen, kopieren, als **QR-Code**
- [ ] **Chat-Liste** (Home): alle Kontakte + letzte Nachricht, Verbindungs-Status-Icon
- [ ] **Kontakt hinzufügen**: ID einfügen *oder* QR scannen → `addContact()`
- [ ] **Chat-Screen**: Nachrichten-Bubbles, Zeitstempel, Sende-Status, Eingabefeld → `sendMessage()`, eingehende via `incomingMessages`
- [ ] **Settings**: Anzeigename, App-Sperre, „ID teilen", Über
- [ ] State-Management (Empfehlung: **Riverpod** oder Provider), Empty-States, Ladeanimationen

**Deine Dateien:** `app/lib/ui/**`, `app/lib/state/**`, `app/assets/**`, `app/pubspec.yaml` (UI-Pakete)
*(Nachtrag: `lib/ui/` und `lib/state/` wurden nie angelegt — der gesamte UI-Code
liegt in `lib/main.dart`. Sie entstehen erst beim Umbau in Phase 4.)*
**Deine Skills:** Flutter/Dart-Widgets, Design, UX. Kein Krypto-Wissen nötig.

---

## 👤 Person B — Krypto, Sicherheit, Backend

**Du besitzt alles Unsichtbare: Schlüssel, Verschlüsselung, Server.** Du
implementierst `MessengerCore` „echt".

**Aufgaben:**
- [ ] **`RealMessengerCore`**: die Schnittstelle mit echter Logik füllen
- [ ] **libsignal_protocol_dart** einbinden: Identity-Key, Prekeys, **X3DH** (Sitzungsaufbau), **Double Ratchet** (Forward Secrecy)
- [ ] **Sicherer lokaler Speicher**: privater Schlüssel + Sessions im **Android Keystore** / `flutter_secure_storage`; Nachrichten-DB verschlüsselt (SQLCipher)
- [ ] **WebSocket-Client**: verbinden, Challenge-Response-Auth (Signatur), senden/empfangen, Reconnect
- [ ] **Prekey-Verwaltung**: Bundle beim Start hochladen, nachfüllen, wenn verbraucht
- [ ] **Server** (liegt schon fertig da → pflegen & deployen):
  - `server/relay_server.py` — Relay + Key-Server *(fertig, getestet)*
  - Härten: **SQLite-Persistenz**, dann **VPS-Deployment mit TLS/HTTPS**
    *(Nachtrag: Der Client bekommt einen **Hostnamen**, nie die rohe IP —
    sonst wäre jeder Serverumzug ein Zwangsupdate für alle Nutzer.)*
- [ ] **Sicherheits-Feature**: „Safety Number"/Fingerprint zum Verifizieren eines Kontakts

**Deine Dateien:** `app/lib/core/**` (außer dem Interface), `server/**`
**Deine Startpunkte:** `core/crypto_core.py` (ID-Konzept als Referenz), `server/relay_server.py` (läuft schon), Doku von libsignal_protocol_dart.
**Deine Skills:** Krypto/Protokolle, Python-Backend, Server/Deployment. Kein Design nötig.

---

## 🤝 Gemeinsam — einmal festlegen, dann „eingefroren"

Diese Dinge ändert ihr **nur zusammen** (sonst bricht die andere Seite):

1. **Das Interface** `MessengerCore` → `app/lib/core/messenger_core.dart`
2. **Die Datenmodelle** `Message`, `Contact` (gleiche Datei)
3. **Die Server-API** (REST + WebSocket-Nachrichtenformat) → im [README](../README.md) / Server-Code
4. **Das ID-Format** (base32 + Prüfsumme) → schon definiert

> Faustregel: Ändert jemand das Interface, gibt's kurz Absprache + beide passen an.

---

## Ordnerstruktur & Ownership

```
secure-messenger/
├─ app/                      ← Flutter-App (wird mit `flutter create .` erzeugt)
│  ├─ lib/
│  │  ├─ core/
│  │  │  ├─ messenger_core.dart        🤝 gemeinsam (der Vertrag)
│  │  │  ├─ mock_messenger_core.dart   👤 A nutzt es, 🤝 gemeinsam gepflegt
│  │  │  └─ real_messenger_core.dart   👤 B (die echte Krypto)
│  │  ├─ ui/                           👤 A (alle Screens/Widgets)
│  │  └─ state/                        👤 A (State-Management)
│  └─ pubspec.yaml
├─ server/                   👤 B (Python Relay-Server, fertig+getestet)
├─ core/                     👤 B (Krypto-Referenz in Python)
└─ docs/                     🤝 (dieser Plan)
```

## Git-Workflow

- **Ein gemeinsames Repo.** Jeder arbeitet in **seinen Ordnern** → kaum Merge-Konflikte.
- **Branch pro Feature** (`feat/chat-screen`, `feat/double-ratchet`), dann **Pull Request**, der andere schaut kurz drüber.
- **`main` bleibt immer lauffähig.**
- **Niemals** private Schlüssel, `.env`, Server-Zugangsdaten committen → `.gitignore`.

---

## Meilensteine (die Punkte, wo ihr zusammensteckt)

| # | Ziel | A liefert | B liefert |
|---|------|-----------|-----------|
| **M1** | Getrennt loslegen | UI läuft mit **Mock** | `RealMessengerCore`-Gerüst + libsignal wählt |
| **M2** | Lokal echt reden | UI unverändert | echte Krypto + WS gegen **lokalen** Server (gleiches WLAN) |
| **M3** | Übers Internet | Feinschliff GUI | Server **auf VPS + TLS**, Reconnect stabil |
| **M4** | Sicher & rund | QR, Verify-Screen | Safety-Numbers, Key-Storage gehärtet, Push |

> **Widerlegt.** Der Satz lautete ursprünglich: „Bei M2 wird in der App nur *eine
> Zeile* getauscht: `MockMessengerCore()` → `RealMessengerCore()`."
>
> Diese Zeile existiert nicht. Die UI wurde nie an das Interface angebunden —
> sie hält ihren Zustand in einem einzigen `StatefulWidget` mit 32 `setState`
> und fest eingetippten Konstanten in `data.dart`. Der Umbau ist eine eigene
> Phase, siehe PLAN.md §5 Phase 4.

---

## Nächste konkrete Schritte

**Person A (du):**
1. Flutter installieren, `app/` mit `flutter create .` anlegen
2. Theme + Navigation aufsetzen
3. Onboarding- und „Meine ID"-Screen gegen `MockMessengerCore` bauen

**Person B:**
1. libsignal_protocol_dart evaluieren, `real_messenger_core.dart` anlegen
2. WebSocket-Auth-Flow gegen den laufenden `relay_server.py` testen
3. Server auf SQLite-Persistenz umstellen, dann VPS-Deployment vorbereiten

**Beide zuerst:** das Interface `messenger_core.dart` gemeinsam durchgehen und abnicken. Danach getrennt Vollgas.
