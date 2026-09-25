// messenger_core.dart
// =====================================================================
//  THE CONTRACT between Person A (UI) and Person B (crypto/backend).
//  FROZEN v1 — change only by mutual agreement.
//
//  * Person A builds the UI against THIS interface + FakeMessengerCore.
//  * Person B implements RealMessengerCore (libsignal + WebSocket + storage).
//  * Neither edits the other's files. This file changes only together.
//
//  Import this one file to get everything (models + errors are re-exported).
// =====================================================================

import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

export 'models.dart';
export 'errors.dart';
export 'store/sicherung.dart' show SicherungPasstNichtException;

/// Max UTF-8 byte length of a single text message.
const int kMaxTextBytes = 4096;

/// Number of words in a recovery phrase (BIP39, 128 bits of entropy).
const int kRecoveryPhraseWords = 12;

/// Wie lange nach dem Absenden eine eigene Nachricht noch bearbeitet werden
/// darf, und wie oft. Die Zahlen sind Signals (support.signal.org, "Edit
/// Message"): Bearbeiten ist zum Ausbessern da, nicht zum Umschreiben der
/// Vergangenheit.
const Duration kBearbeitungsFrist = Duration(hours: 24);
const int kMaxBearbeitungen = 10;

/// Wie lange "fuer alle loeschen" angeboten wird — ebenfalls Signals Frist.
const Duration kWiderrufsFrist = Duration(hours: 24);

abstract class MessengerCore {
  // ------------------------------------------------------------- identity
  //
  // NOTE ON THE LIFECYCLE (changed 2026-07-25, see PLAN.md §2):
  // `initialize()` used to create an identity on first launch. That is wrong
  // once recovery phrases exist: the user must first CHOOSE between "new
  // identity" and "restore from phrase", and that choice happens in the UI.
  // Silently creating one would leave a user who wanted to restore already
  // holding a different identity.
  //
  // The flow is therefore:
  //     initialize()            -> false  (no identity yet)
  //        UI shows welcome screen
  //        -> createIdentity()      (new)      -> show the 12 words
  //        -> restoreIdentity(...)  (restore)
  //     initialize()            -> true   (identity loaded, go to chats)

  /// Open local storage and load an existing identity if there is one.
  /// Does NOT create anything. Idempotent.
  ///
  /// Returns `true` if an identity was loaded (proceed to the app), `false` if
  /// none exists yet (show onboarding).
  /// Throws `StorageException`.
  Future<bool> initialize();

  /// True once an identity is loaded — i.e. [initialize] returned true, or
  /// [createIdentity] / [restoreIdentity] completed.
  bool get isInitialized;

  /// Whether local storage already holds an identity. Cheap, synchronous
  /// snapshot of what [initialize] returned.
  bool get hasIdentity;

  /// The own address ("long number") to share so others can add you.
  /// Throws `NotInitializedException` if read before an identity exists.
  String get myId;

  /// Create a BRAND NEW identity and persist it.
  ///
  /// Returns the [kRecoveryPhraseWords]-word recovery phrase. The UI MUST show
  /// it and make the user write it down — it is the only way back after losing
  /// the device, and it cannot be recovered afterwards from anywhere else.
  ///
  /// Throws `StateError` if an identity already exists (call [initialize]
  /// first), `StorageException`, `CryptoException`.
  Future<List<String>> createIdentity();

  /// Restore an identity from a recovery phrase and persist it.
  /// Returns the resulting [myId].
  ///
  /// The old device (if any) keeps working until it next connects; the server
  /// hands out the newest prekeys, so "last restore wins". Message history is
  /// NOT restored — only the identity and, with it, the ability to be reached.
  ///
  /// Throws `InvalidRecoveryPhraseException` if the phrase fails its checksum,
  /// `StateError` if an identity already exists, `StorageException`.
  Future<String> restoreIdentity(List<String> words);

  /// Cheap, OFFLINE check of a recovery phrase (word list + checksum).
  /// The UI calls this to validate the input fields before [restoreIdentity].
  bool isValidRecoveryPhrase(List<String> words);

  /// The recovery phrase of the current identity, for "show my phrase" in
  /// settings. Guard this behind device authentication in the UI.
  /// Throws `NotInitializedException`, `StorageException`.
  Future<List<String>> getRecoveryPhrase();

  /// Cheap, OFFLINE format + checksum check of a peer address (no network).
  /// The UI calls this to validate the paste field before [addContact].
  bool isValidAddress(String address);

  // ----------------------------------------------------------- connection
  /// Open and authenticate the link to the relay/key server.
  /// Does NOT throw on network failure — progress/failure is reported via
  /// [connectionStateChanges] / [connectionState]. Throws only
  /// `NotInitializedException`.
  Future<void> connect();

  /// Close the server link. Safe to call when already disconnected.
  Future<void> disconnect();

  /// Current link state (synchronous snapshot).
  ConnectionState get connectionState;

  /// Broadcast stream of link-state transitions. Does NOT replay the current
  /// value on listen — read [connectionState] once, then listen.
  Stream<ConnectionState> get connectionStateChanges;

  // ------------------------------------------------------------- contacts
  /// All active + pending contacts, newest first.
  Future<List<Contact>> getContacts();

  /// Add a peer by address and send a contact request.
  /// Returns the new contact in `ContactState.outgoingPending`.
  /// Throws `InvalidAddressException`, `NotInitializedException`.
  Future<Contact> addContact(String address, {String? displayName});

  /// Accept an incoming request (contact in `ContactState.incomingPending`).
  /// Throws `UnknownContactException`.
  Future<void> acceptRequest(String contactId);

  /// Decline/ignore an incoming request.
  Future<void> declineRequest(String contactId);

  /// Remove a contact locally and tear down the session. Unilateral, no confirm.
  Future<void> removeContact(String contactId);

  /// Broadcast stream of contact-side events (incoming request, request
  /// accepted by peer, declined, removed). See [ContactEvent].
  Stream<ContactEvent> get contactEvents;

  // ------------------------------------------------------------- messages
  /// Local history for a conversation, oldest → newest.
  /// Throws `UnknownContactException`.
  Future<List<Message>> getMessages(String contactId, {int limit = 50, DateTime? before});

  /// Encrypt + send a text message. Returns immediately with the stored
  /// [Message] in `MessageStatus.sending`; later transitions arrive on
  /// [messageStatusUpdates]. Encryption/session setup happen internally.
  /// Throws `UnknownContactException`, `MessageTooLargeException`,
  /// `NotInitializedException`.
  ///
  /// [antwortAuf] nennt die Nachricht, auf die geantwortet wird. Es reist nur
  /// die Kennung, kein Zitat (siehe Payload.antwortAuf).
  ///
  /// [um] plant die Nachricht: sie wird sofort gespeichert und geht zu diesem
  /// Zeitpunkt hinaus (oder beim ersten Verbinden danach). Ihre Verfasszeit
  /// ist dann [um], nicht jetzt — die Gegenstelle soll sie dort einsortieren,
  /// wo sie hingehoert.
  Future<Message> sendMessage(String contactId, String text,
      {String? antwortAuf, DateTime? um});

  // ------------------------------------------ reactions, edits, deletions

  /// Setzt die eigene Reaktion auf eine Nachricht; null oder leer nimmt sie
  /// zurueck. Je Person und Nachricht eine, eine neue ersetzt die alte.
  ///
  /// Geht auch ohne Verbindung: sie wartet im Ausgang.
  Future<void> reagiere(String contactId, String messageId, String? zeichen);

  /// Nachrichtenkennung → wer → Zeichen, fuer eine ganze Unterhaltung.
  Future<Map<String, Reaktionen>> getReaktionen(String contactId);

  /// Aendert den Text einer EIGENEN Textnachricht.
  ///
  /// Wirft `BearbeitungNichtMoeglichException`, wenn die Nachricht nicht
  /// eigene Text ist, widerrufen wurde, aelter als [kBearbeitungsFrist] ist
  /// oder schon [kMaxBearbeitungen] Mal bearbeitet wurde.
  Future<Message> bearbeite(String contactId, String messageId, String neuerText);

  /// "Fuer alle loeschen" — nur eigene Nachrichten, nur innerhalb von
  /// [kWiderrufsFrist]. Wirft sonst `BearbeitungNichtMoeglichException`.
  Future<void> widerrufe(String contactId, String messageId);

  /// Schickt eine Umfrage. Wirft [ArgumentError], wenn sie nicht taugt (zu
  /// wenige oder zu viele Antworten, zu lang).
  Future<Message> sendeUmfrage(String contactId, Umfrage umfrage,
      {String? antwortAuf});

  /// Gibt die eigene Stimme ab; leer zieht sie zurueck.
  Future<void> stimme(String contactId, String umfrageId, List<int> auswahl);

  /// Umfrage → wer → Auswahl, fuer eine ganze Unterhaltung.
  Future<Map<String, Stimmen>> getStimmen(String contactId);

  /// Heftet eine Nachricht oben an ([an]) oder loest sie — fuer beide Seiten.
  /// Hoechstens drei je Unterhaltung; die vierte verdraengt die aelteste.
  Future<void> hefteAn(String contactId, String messageId, bool an);

  /// "Fuer mich loeschen" — jede Nachricht, nur auf diesem Geraet.
  Future<void> loescheFuerMich(String contactId, String messageId);

  /// Markiert eine Nachricht mit einem Stern ([an]) oder nimmt ihn. Nur auf
  /// diesem Geraet, die Gegenstelle erfaehrt nichts.
  Future<void> setzeStern(String contactId, String messageId, bool an);

  /// Alle markierten Nachrichten, zuletzt markierte zuerst.
  Future<List<Message>> sterne();

  /// Meldet die Unterhaltung (Kontaktadresse), deren Verlauf sich geaendert
  /// hat, OHNE dass eine neue Nachricht dazukam: bearbeitet, widerrufen,
  /// Reaktion gesetzt. Die Oberflaeche laedt diese Unterhaltung dann neu.
  Stream<String> get verlaufGeaendert;

  /// Sucht in allen Textnachrichten (oder nur in [contactId]), neueste zuerst.
  /// Nur lokal — es gibt keinen Server, den man fragen koennte.
  Future<List<Message>> suche(String text, {String? contactId, int limit = 100});

  /// Sagt der Gegenstelle, dass hier gerade getippt wird ([tippt]) oder
  /// nicht mehr. Tut NICHTS, wenn die Anzeige aus ist, keine Verbindung
  /// besteht, der Relay keine fluechtigen Rahmen kennt oder es noch keine
  /// Sitzung gibt — eine Tipp-Meldung ist nie ein Grund, ein Schluesselbuendel
  /// zu holen.
  Future<void> meldeTippen(String contactId, bool tippt);

  /// Tipp-Meldungen der Gegenstellen, nur wenn die eigene Anzeige an ist.
  Stream<TippMeldung> get tippen;

  /// Eigene Loeschfrist fuer eine Unterhaltung: null folgt der
  /// Grundeinstellung, [Duration.zero] heisst "hier nie".
  Future<void> setzeChatFrist(String contactId, Duration? frist);

  /// Der Verlauf als verschluesselte Datei — Kontakte, Nachrichten,
  /// Reaktionen, Stimmen, Anleitungen der Anhaenge; KEINE Schluessel und
  /// Sitzungen (siehe lib/core/store/sicherung.dart). Aufgehen tut sie nur
  /// mit denselben zwoelf Woertern.
  ///
  /// [mitDateien]: die geholten Anhaenge selbst kommen mit — hoechstens
  /// [Sicherung.dateienGrenze] zusammen; was darueber liegt, bleibt draussen
  /// (Einmal-Ansichten immer).
  Future<Uint8List> erstelleSicherung({bool mitDateien = false});

  /// Spielt eine Sicherung ein, ohne Vorhandenes zu ueberschreiben. Rueckgabe:
  /// wie viele Nachrichten dazukamen. Wirft `SicherungPasstNichtException`,
  /// wenn sie zu einer anderen Identitaet gehoert oder beschaedigt ist.
  Future<int> spieleSicherungEin(Uint8List daten);

  /// Legt die Unterhaltung "Notizen" an, falls es sie noch nicht gibt, und
  /// gibt ihre Kennung zurueck — die eigene Adresse.
  ///
  /// Was dort geschrieben wird, geht an niemanden; es wird nur an die eigenen
  /// anderen Geraete gespiegelt (wie bei Signals "Notiz an mich").
  Future<String> oeffneNotizen();

  // ---------------------------------------------------------------- Gruppen

  /// Legt eine Gruppe an; [mitglieder] muessen aktive Kontakte sein. Man
  /// selbst ist Admin. Wirft [ArgumentError], wenn es zu viele sind oder der
  /// Name nicht taugt.
  ///
  /// Alle Nachrichten-Methoden oben nehmen die Gruppenkennung wie eine
  /// Kontaktadresse: getMessages, sendMessage, sendeAnhang, reagiere, ...
  Future<Gruppe> legeGruppeAn(String name, List<String> mitglieder);

  Future<List<Gruppe>> getGruppen();

  /// Welche Mitglieder eine eigene Gruppennachricht schon haben.
  Future<Set<String>> zugestelltAn(String gruppe, String messageId);

  /// Verteilerlisten — nur oertlich, der Relay erfaehrt nichts.
  Future<List<Verteiler>> getVerteiler();
  Future<void> speichereVerteiler(List<Verteiler> liste);

  /// Nur der Admin. Neue muessen aktive Kontakte sein.
  Future<void> fuegeZuGruppeHinzu(String gruppeId, List<String> neue);

  /// Nur der Admin.
  Future<void> entferneAusGruppe(String gruppeId, String mitglied);

  /// Nur der Admin.
  Future<void> benenneGruppe(String gruppeId, String name);

  /// Austreten. Der Verlauf bleibt lesbar; schreiben geht danach nicht mehr.
  Future<void> verlasseGruppe(String gruppeId);

  /// Eine Gruppe ist entstanden oder hat sich geaendert.
  Stream<String> get gruppenGeaendert;

  /// Anheften, archivieren, stummschalten — nur auf diesem Geraet.
  Future<void> setzeOrdnung(String contactId,
      {bool? angeheftet, bool? archiviert, bool? stumm});

  /// Broadcast stream of newly received, already-DECRYPTED inbound messages.
  /// The core also persists them; this is the live push for the UI.
  Stream<Message> get incomingMessages;

  /// Broadcast stream of status changes for messages I sent
  /// (sending → sent → delivered → read, or → failed).
  Stream<MessageStatusUpdate> get messageStatusUpdates;

  // ------------------------------------------------------------ Anhaenge
  //
  // Hinzugekommen 2026-07-25 (Vertrag v1.3). Der Weg dahinter steht in
  // lib/core/anhang/ und in docs/ZWISCHENLAGER.md.
  //
  // WAS UEBER DEN RELAY GEHT, ist nur die Anleitung: wo die Stuecke liegen und
  // womit sie aufgehen. Die Bytes selbst laufen ueber dateien.bitdm.net und
  // sind dort verschluesselt — der Schluessel kommt dort nie vorbei.

  /// Schickt [datei] an [contactId].
  ///
  /// Kehrt erst zurueck, wenn ALLES oben ist und die Anleitung verschickt
  /// wurde — anders als [sendMessage]. Der Grund ist die Dauer: bei drei
  /// Gigabyte laeuft das minutenlang, und der Aufrufer braucht ein Ende, an
  /// dem er weiss, dass es geklappt hat. Der Fortschritt kommt waehrenddessen
  /// ueber [anhangFortschritt].
  ///
  /// Wirft `UnknownContactException`, `AnhangZuGross`, `LagerVoll`,
  /// `RelayException` (etwa "Tagesmenge erschoepft"), `NotInitializedException`.
  /// [name] und [groesse] werden hereingereicht, wenn der Pfad sie nicht
  /// hergibt. Der Dateiwaehler liefert /proc/self/fd/<nr>; dort waere der
  /// geratene Name "7".
  Future<Message> sendeAnhang(String contactId, File datei,
      {String? name, int? groesse, bool einmal = false});

  /// Eine empfangene Einmal-Ansicht wurde angesehen: Datei loeschen, Zustand
  /// [AnhangZustand.verbraucht]. Tut nichts bei einem gewoehnlichen Anhang.
  Future<void> verbraucheEinmal(String contactId, String messageId);

  /// Holt einen empfangenen Anhang ins Dateisystem.
  ///
  /// AUSDRUECKLICH UND NICHT VON SELBST. Ein Anhang kann drei Gigabyte gross
  /// sein; ihn ungefragt zu holen, waere ein Griff in fremdes Datenvolumen.
  /// Die Oberflaeche zeigt Name und Groesse und fragt.
  ///
  /// Rueckgabe: der Eintrag im neuen Zustand. Bei Erfolg
  /// [AnhangZustand.da] mit gesetztem Pfad.
  ///
  /// Wirft `UnknownContactException`, `AnhangKaputt`, `LagerLeer`.
  Future<AnhangEintrag> holeAnhang(String contactId, String messageId);

  /// Die Anhaenge einer Unterhaltung, nach Nachrichtenkennung.
  ///
  /// In einem Rutsch statt je Nachricht: eine Unterhaltung mit fuenfzig
  /// Anhaengen ergaebe sonst fuenfzig Abfragen beim Zeichnen einer Liste.
  Future<Map<String, AnhangEintrag>> getAnhaenge(String contactId);

  /// Fortschritt beim Schicken und Holen. Meldet sich mehrmals je Sekunde.
  Stream<AnhangFortschritt> get anhangFortschritt;

  /// Zustandswechsel eines Anhangs (angekuendigt → laedt → da / gescheitert).
  Stream<AnhangEintrag> get anhangAenderungen;

  /// Tell the core the user has opened/viewed [contactId]'s messages, so it can
  /// send a read receipt to the peer (if read receipts are enabled). No-op
  /// otherwise. Throws `UnknownContactException`.
  Future<void> markRead(String contactId);

  /// Wie viele fremde Nachrichten je Unterhaltung ungelesen sind — nur
  /// Unterhaltungen mit mindestens einer. Zaehlt ab dem letzten [markRead].
  Future<Map<String, int>> ungelesenJeChat();

  // ------------------------------------------------------------ settings
  /// The settings the core enforces. Persisted in the encrypted database.
  ///
  /// Added 2026-07-25 (contract v1.2). Before that the three switches existed
  /// only as UI state and changed nothing — see [AppPreferences].
  Future<AppPreferences> getPreferences();

  /// Store settings. Takes effect immediately.
  ///
  /// Changing [AppPreferences.messageLifetime] does NOT rewrite existing
  /// messages: each one keeps the expiry it was given when it arrived.
  /// Otherwise turning the setting off would resurrect messages the user
  /// believed were gone, and turning it on would silently delete history.
  Future<void> setPreferences(AppPreferences prefs);

  /// Ob diesem Kontakt gegenueber die eigene Anwesenheit gezeigt wird.
  ///
  /// WIRKT IN BEIDE RICHTUNGEN, und das ist keine Bequemlichkeit: mit `false`
  /// wird fuer ihn kein Leuchtfeuer mehr ausgesendet UND keines von ihm mehr
  /// erwartet. Nur eine der beiden Richtungen abzuschalten waere die
  /// schlechtere Haelfte von beidem — man faende ihn nicht mehr, zeigte ihm
  /// aber weiter, wo man ist.
  ///
  /// Nachrichten an ihn nehmen danach immer den Relay. Das ist die Folge, die
  /// die Oberflaeche mitsagen muss.
  Future<void> setContactPresence(String contactId, bool zeigen);

  /// Delete every message whose time is up. Returns how many went.
  ///
  /// Call on start and whenever the app comes back to the foreground. Cheap
  /// when there is nothing to do.
  Future<int> purgeExpiredMessages();

  // --------------------------------------------------------- verification
  /// The out-of-band verification number for a contact (Signal-style).
  /// Throws `UnknownContactException`.
  Future<SafetyNumber> getSafetyNumber(String contactId);

  /// Mark a contact verified (or not) after the user compared numbers.
  Future<void> setVerified(String contactId, bool verified);

  // ------------------------------------------------------------ lifecycle
  /// Delete the identity, every key and the whole local database.
  ///
  /// Added 2026-07-25 (v1.1 of this contract). The UI has always had a "wipe
  /// everything" button; until now nothing behind it actually deleted
  /// anything, because there was nothing real to delete. There is now.
  ///
  /// WHY THIS IS FINAL: the local database is encrypted with a key derived
  /// from the recovery entropy. Deleting that entropy makes the file
  /// permanently unreadable — even to us, even if the bytes survive on flash
  /// storage. That is the strongest form of deletion available on a phone,
  /// and it is why this cannot be undone without the 12 words.
  ///
  /// After this the core is back to its pre-identity state: [initialize]
  /// returns false and the UI must show onboarding again. Unlike [dispose]
  /// the instance stays usable.
  Future<void> wipeEverything();

  /// Tell the relay where to nudge this device when it is offline, or null to
  /// stop. Silently does nothing when not connected — a push endpoint only
  /// speeds delivery up; it is never required for a message to arrive.
  Future<void> setPushEndpoint(String? endpoint);

  /// Close the database and drop every derived key from memory, WITHOUT
  /// deleting anything. Call when the app lock should re-engage.
  ///
  /// WHY THIS IS NOT A UI FLAG: hiding the screen behind an overlay would
  /// leave the database open and the keys live in RAM. Anyone who can read
  /// the process — a debugger, a memory dump, a rooted phone — walks past the
  /// overlay. This actually closes the file and forgets the keys, so the next
  /// [initialize] has to go through the key slot again.
  ///
  /// The streams above stay open; the instance stays usable. After this
  /// [isInitialized] is false and [initialize] behaves as it does on a cold
  /// start: it asks the secret store, which is where the lock lives.
  Future<void> lock();

  /// Release all resources and CLOSE every stream above. The instance is
  /// unusable afterwards. Call on app shutdown.
  Future<void> dispose();
}
