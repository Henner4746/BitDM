import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'core/messenger_core.dart';
import 'core/real_messenger_core.dart';
import 'core/secret_store.dart';
import 'data.dart';
import 'painters.dart';

/// Wohin sich die App verbindet.
///
/// Ueberschreibbar beim Bauen:
///   flutter build apk --dart-define=BITDM_RELAY=https://relay.example.org
///
/// Der Relay darf NIE hinter einem Proxy wie Cloudflare stehen — der saehe
/// sonst zu jeder Verbindung, wer wann mit wem spricht. Genau die Angabe, die
/// diese App vermeiden soll.
const String relayBasis = String.fromEnvironment(
  'BITDM_RELAY',
  defaultValue: 'https://relay.bitdm.net',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Ein Verzeichnis, das dem Betriebssystem gehoert und nicht in Sicherungen
  // oder in den Dateimanager wandert.
  final verzeichnis = await getApplicationSupportDirectory();

  final core = RealMessengerCore(
    secretStore: DeviceSecretStore(),
    databasePath: '${verzeichnis.path}/bitdm.db',
    relayUri: Uri.parse(relayBasis),
  );

  runApp(BitApp(state: AppState(core)));
}

class BitApp extends StatelessWidget {
  const BitApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BitDM',
      debugShowCheckedModeBanner: false,
      home: Home(state: state),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key, required this.state});

  final AppState state;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  String screen = 'onboard';
  String? chat;
  bool reqSent = false, sheet = false, panic = false, wiped = false, copied = false;

  AppState get st => widget.state;

  /// Adressen der Unterhaltungen, die in der Liste erscheinen.
  List<String> get contacts => st.aktiveKontakte.map((c) => c.id).toList();

  @override
  void initState() {
    super.initState();
    st.addListener(_aktualisiere);
    st.boot().then((_) {
      if (!mounted) return;
      // Wer schon eine Identitaet hat, sieht das Onboarding nicht wieder.
      setState(() => screen = st.hatIdentitaet ? 'chats' : 'onboard');
    });
  }

  void _aktualisiere() {
    if (mounted) setState(() {});
  }

  String lang = 'en', mode = 'dark';
  Map<String, bool> auth = {'bio': false, 'passkey': false, 'hw': false, 'totp': false};
  String? enroll;
  Map<String, dynamic> settings = {'shot': true, 'rec': false, 'eph': '24h'};

  final draftCtl = TextEditingController();
  final addCtl = TextEditingController();
  final codeCtl = TextEditingController();

  Pal get p => mode == 'dark' ? palDark : palLight;
  List<Color> get avp => mode == 'dark' ? avPalDark : avPalLight;
  String t(String k) => strings[lang]![k] ?? k;

  @override
  void dispose() {
    st.removeListener(_aktualisiere);
    draftCtl.dispose();
    addCtl.dispose();
    codeCtl.dispose();
    super.dispose();
  }

  // ---- fonts (bundled locally; the app never fetches them at runtime) ----
  //
  // Both families are variable fonts with a `wght` axis, so a single file
  // covers every weight the UI uses (w300 … w900). `fontWeight` alone does not
  // drive that axis reliably, so the axis is set explicitly via fontVariations
  // and `fontWeight` is kept for Flutter's own fallback/metrics handling.
  TextStyle _font(String family, double size, FontWeight weight, Color? color, double? spacing, double height) {
    return TextStyle(
      fontFamily: family,
      fontVariations: [FontVariation('wght', weight.value.toDouble())],
      fontSize: size,
      fontWeight: weight,
      color: color,
      letterSpacing: spacing,
      height: height,
    );
  }
  TextStyle doto({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? spacing, double height = 1.2}) =>
      _font('Doto', size, weight, color, spacing, height);
  TextStyle mono({double size = 14, FontWeight weight = FontWeight.w400, Color? color, double? spacing, double height = 1.4}) =>
      _font('Chivo Mono', size, weight, color, spacing, height);

  // ---- helpers ----
  /// Uhrzeit einer Nachricht, bei aelteren zusaetzlich der Tag.
  String zeitVon(DateTime utc) {
    final l = utc.toLocal();
    final heute = DateTime.now();
    final hm = '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}';
    if (l.year == heute.year && l.month == heute.month && l.day == heute.day) {
      return hm;
    }
    return '${l.day.toString().padLeft(2, '0')}.'
        '${l.month.toString().padLeft(2, '0')}. $hm';
  }

  String ephLabel() {
    final e = settings['eph'];
    return e == 'off' ? t('off') : e == '1h' ? t('h1') : e == '7d' ? t('d7') : t('h24');
  }

  String nowHm() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  // ---- actions ----
  void go(String s) => setState(() { screen = s; sheet = false; panic = false; });

  /// Legt eine echte Identitaet an und zeigt danach die zwoelf Woerter.
  ///
  /// Der Entwurf sprang von hier direkt zu den Anmeldeverfahren. Das ging
  /// nicht: die Phrase ist der EINZIGE Weg zurueck, wenn das Telefon weg ist,
  /// und wer sie nie zu sehen bekommt, verliert seine Identitaet beim ersten
  /// kaputten Bildschirm. Deshalb liegt jetzt ein Schritt dazwischen.
  Future<void> doCreate() async {
    setState(() { screen = 'creating'; wiped = false; });
    await st.identitaetAnlegen();
    if (!mounted) return;
    setState(() => screen = 'phrase');
  }

  Future<void> send() async {
    final d = draftCtl.text.trim();
    if (d.isEmpty || chat == null) return;
    draftCtl.clear();
    await st.senden(chat!, d);
  }

  void startEnroll(String key) {
    setState(() { enroll = key; codeCtl.clear(); });
    if (key != 'totp') {
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (enroll != key || !mounted) return;
        setState(() { enroll = null; auth[key] = true; });
      });
    }
  }

  void methodAct(String key) {
    final on = auth[key]!;
    final count = auth.values.where((v) => v).length;
    if (on) {
      if (count <= 1) return;
      setState(() => auth[key] = false);
    } else {
      startEnroll(key);
    }
  }

  void confirmTotp() {
    if (codeCtl.text.length < 6) return;
    setState(() { auth['totp'] = true; enroll = null; codeCtl.clear(); });
  }

  /// Die eigene Adresse, wie der Entwurf sie zeigt: Vierergruppen mit
  /// Bindestrichen. Solange noch keine Identitaet da ist, bleibt es leer.
  String get meineAdresseAnzeige =>
      st.meineAdresse.isEmpty ? '' : adresseFormatiert(st.meineAdresse);

  void copyId() {
    if (st.meineAdresse.isEmpty) return;
    // In die Zwischenablage geht die ROHE Adresse ohne Bindestriche — die
    // Gegenstelle fuegt sie irgendwo ein, und dort soll sie ohne Nacharbeit
    // funktionieren.
    Clipboard.setData(ClipboardData(text: st.meineAdresse));
    setState(() => copied = true);
    Future.delayed(const Duration(milliseconds: 1400), () { if (mounted) setState(() => copied = false); });
  }

  Future<void> sendReq() async {
    final eingabe = addCtl.text.replaceAll(RegExp(r'[\s\-]'), '');
    if (eingabe.isEmpty) return;
    final ok = await st.kontaktHinzufuegen(eingabe);
    if (!mounted) return;
    setState(() => reqSent = ok);
  }

  Future<void> acceptReq(String id) async {
    await st.anfrageAnnehmen(id);
    if (!mounted) return;
    await st.unterhaltungOeffnen(id);
    if (!mounted) return;
    setState(() { screen = 'chat'; chat = id; });
  }

  Future<void> oeffneChat(String id) async {
    setState(() { screen = 'chat'; chat = id; sheet = false; });
    await st.unterhaltungOeffnen(id);
  }

  void doWipe() => setState(() {
        final l = lang, m = mode;
        screen = 'chats'; chat = null; reqSent = false; sheet = false; panic = false;
        wiped = true; copied = false;
        auth = {'bio': false, 'passkey': false, 'hw': false, 'totp': false};
        enroll = null;
        settings = {'shot': true, 'rec': false, 'eph': '24h'};
        lang = l; mode = m;
        draftCtl.clear(); addCtl.clear(); codeCtl.clear();
      });

  // ---- small UI atoms ----
  Widget h2(String s, {double size = 26}) =>
      Text(s.toUpperCase(), style: doto(size: size, weight: FontWeight.w700, color: p.ink, spacing: 0.4, height: 1.1));

  Widget label6(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s.toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1.8)),
      );

  Widget outlineBtn(String labelTxt, VoidCallback onTap,
      {bool accent = true, double fontSize = 12, EdgeInsets? padding, FontWeight weight = FontWeight.w600, Color? textColor}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: padding ?? const EdgeInsets.symmetric(vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent ? p.accent : p.line),
        ),
        child: Text(labelTxt.toUpperCase(),
            style: mono(size: fontSize, weight: weight, color: textColor ?? (accent ? p.ink : p.muted), spacing: fontSize * 0.12)),
      ),
    );
  }

  Widget iconBtn(String glyph, VoidCallback onTap, {Color? color, double fontSize = 15}) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 30, height: 30, alignment: Alignment.center,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
          child: Text(glyph, style: TextStyle(color: color ?? p.muted, fontSize: fontSize, height: 1)),
        ),
      );

  // ---- build ----
  @override
  Widget build(BuildContext context) {
    final showNav = screen == 'chats' || screen == 'id' || screen == 'set';
    return Scaffold(
      backgroundColor: p.bg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(child: buildScreen()),
                if (showNav) buildNav(),
              ],
            ),
            if (enroll != null) enrollModal(),
            if (sheet && screen == 'chat') encSheet(),
            if (panic && screen == 'set') panicModal(),
          ],
        ),
      ),
      floatingActionButton: (sheet || panic || enroll != null)
          ? null
          : FloatingActionButton.small(
              backgroundColor: p.surf,
              foregroundColor: p.accLight,
              shape: const CircleBorder(),
              onPressed: showDevJump,
              child: const Text('≡', style: TextStyle(fontSize: 20, height: 1)),
            ),
    );
  }

  Widget buildScreen() {
    if (!st.bereit) return const SizedBox.shrink();
    switch (screen) {
      case 'creating': return arbeitetScreen();
      case 'phrase': return phraseScreen();
      case 'secure': return secureScreen();
      case 'id': return idScreen();
      case 'add': return addScreen();
      case 'chats': return chatsScreen();
      case 'chat': return chatScreen();
      case 'set': return settingsScreen();
      default: return onboardScreen();
    }
  }

  // ---- ONBOARD ----
  Widget onboardScreen() {
    return LayoutBuilder(builder: (ctx, con) {
      return SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: con.maxHeight),
          child: IntrinsicHeight(
            child: Padding(
              padding: const EdgeInsets.all(22),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46, height: 46, alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                    child: Text('B', style: doto(size: 22, weight: FontWeight.w900, color: p.accLight)),
                  ),
                  const SizedBox(height: 16),
                  Text('${t('h1a')}\n${t('h1b')}', style: doto(size: 36, weight: FontWeight.w800, color: p.ink, height: 1.05, spacing: 0.4)),
                  const SizedBox(height: 10),
                  Text(t('intro'), style: mono(size: 13.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
                  const SizedBox(height: 16),
                  bullet(t('b1')), bullet(t('b2')), bullet(t('b3')),
                  if (wiped) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
                      child: Text(t('wiped'), style: mono(size: 12, color: p.tintInk)),
                    ),
                  ],
                  const SizedBox(height: 20),
                  outlineBtn(t('create'), doCreate, padding: const EdgeInsets.all(15), fontSize: 13),
                  const SizedBox(height: 8),
                  Text(t('createNote'), style: mono(size: 11, color: p.dim)),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget bullet(String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('—', style: TextStyle(color: p.accent, fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(child: Text(s, style: mono(size: 12, color: p.dim))),
        ]),
      );

  // ---- WIRD ANGELEGT ----
  Widget arbeitetScreen() => Center(
        child: Text(t('creating').toUpperCase(),
            style: mono(size: 12, color: p.dim, spacing: 1.8)),
      );

  // ---- WIEDERHERSTELLUNGSPHRASE ----
  //
  // Diesen Bildschirm gab es im Entwurf nicht. Er ist trotzdem nicht optional:
  // die zwoelf Woerter sind der einzige Weg zurueck, wenn das Telefon
  // verloren, kaputt oder geloescht ist. Es gibt keinen Server, bei dem man
  // sich ausweisen und die Identitaet zurueckholen koennte — wer sie nicht
  // notiert hat, ist weg.
  //
  // Gestaltet mit denselben Bausteinen wie der Rest, damit sich nichts
  // Fremdes anfuehlt.
  Widget phraseScreen() {
    final woerter = st.frischePhrase ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('phraseTitle')),
        const SizedBox(height: 6),
        Text(t('phraseSub'),
            style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (var i = 0; i < woerter.length; i++)
                SizedBox(
                  width: (MediaQuery.of(context).size.width - 44 - 6) / 2,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                    decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
                    child: Row(children: [
                      SizedBox(
                        width: 20,
                        child: Text('${i + 1}', style: mono(size: 10, color: p.dim)),
                      ),
                      Expanded(
                        child: Text(woerter[i],
                            style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
                      ),
                    ]),
                  ),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: p.tint,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: p.tintLine),
          ),
          child: Text(t('phraseWarn'), style: mono(size: 11.5, color: p.tintInk, height: 1.5)),
        ),
        const SizedBox(height: 12),
        outlineBtn(t('phraseDone'), () {
          st.phraseBestaetigt();
          go('secure');
        }, padding: const EdgeInsets.all(13)),
      ]),
    );
  }

  // ---- SECURE ----
  Widget secureScreen() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('secureTitle')),
        const SizedBox(height: 6),
        Text(t('secureSub'), style: mono(size: 12.5, weight: FontWeight.w300, color: p.muted, height: 1.6)),
        const SizedBox(height: 16),
        for (final k in ['bio', 'passkey', 'hw', 'totp']) ...[methodRow(k, statusMode: true), const SizedBox(height: 6)],
        const SizedBox(height: 4),
        Text(t('secureFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const Spacer(),
        Row(children: [
          Expanded(child: outlineBtn(t('secureSkip'), () => go('id'), accent: false, padding: const EdgeInsets.all(13), weight: FontWeight.w400)),
          const SizedBox(width: 8),
          Expanded(child: outlineBtn(t('secureDone'), () => go('id'), padding: const EdgeInsets.all(13))),
        ]),
      ]),
    );
  }

  Widget methodRow(String key, {bool statusMode = true}) {
    final on = auth[key]!;
    final mark = on ? '✓' : '·';
    final right = statusMode ? (on ? t('on2') : t('offMethod')) : (on ? t('remove') : t('add'));
    return GestureDetector(
      onTap: () => methodAct(key),
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Container(
            width: 26, height: 26, alignment: Alignment.center,
            decoration: BoxDecoration(color: on ? p.tint : p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: on ? p.accent : p.line)),
            child: Text(mark, style: doto(size: 12, weight: FontWeight.w600, color: on ? p.accLight : p.dim)),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t(key), style: TextStyle(fontSize: 13.5, color: p.ink)),
              Text(t('${key}Sub'), style: mono(size: 11, color: p.dim, height: 1.35)),
            ]),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: on ? p.tint : Colors.transparent, borderRadius: BorderRadius.circular(4), border: Border.all(color: on ? p.tintLine : p.line)),
            child: Text(right.toUpperCase(), style: mono(size: 10, weight: FontWeight.w500, color: on ? p.tintInk : p.dim, spacing: 1.2)),
          ),
        ]),
      ),
    );
  }

  // ---- MY ID ----
  Widget idScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('myId')),
        const SizedBox(height: 4),
        Text(t('myIdSub'), style: mono(size: 12, color: p.dim)),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
          child: QrView(st.meineAdresse, p.ink, p.surf),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final blk in meineAdresseAnzeige.split('-'))
            SizedBox(
              width: (MediaQuery.of(context).size.width - 44 - 6) / 2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(4)),
                child: Text(blk, style: doto(size: 16, weight: FontWeight.w600, color: p.ink, spacing: 1.4)),
              ),
            ),
        ]),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: outlineBtn(copied ? t('copied') : t('copy'), copyId, padding: const EdgeInsets.all(11))),
          const SizedBox(width: 8),
          Expanded(child: outlineBtn(t('share'), () {}, accent: false, padding: const EdgeInsets.all(11), weight: FontWeight.w400)),
        ]),
        const SizedBox(height: 16),
        Text(t('idNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }

  // ---- ADD ----
  Widget addScreen() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 17, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          iconBtn('‹', () => go('chats')),
          const SizedBox(width: 11),
          h2(t('addTitle'), size: 20),
        ]),
        const SizedBox(height: 16),
        Text(t('idLabel').toUpperCase(), style: mono(size: 10.5, color: p.dim, spacing: 1.6)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
          padding: const EdgeInsets.all(11),
          child: TextField(
            controller: addCtl,
            maxLines: 3,
            style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 1.4, height: 1.7),
            cursorColor: p.accent,
            decoration: InputDecoration.collapsed(hintText: 'B3XK-7QMD-2FTV-…', hintStyle: doto(size: 15, weight: FontWeight.w600, color: p.dim, spacing: 1.4, height: 1.7)),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          smallBtn(t('paste'), () async {
            final d = await Clipboard.getData(Clipboard.kTextPlain);
            final txt = d?.text?.trim();
            if (txt == null || txt.isEmpty || !mounted) return;
            setState(() => addCtl.text = txt);
          }),
          const SizedBox(width: 8),
          smallBtn(t('scan'), () {}),
        ]),
        const SizedBox(height: 16),
        outlineBtn(t('sendReq'), sendReq, padding: const EdgeInsets.all(13)),
        if (reqSent) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(4)),
                  child: Text(t('pending').toUpperCase(), style: mono(size: 10, weight: FontWeight.w500, color: p.tintInk, spacing: 1.2)),
                ),
                const SizedBox(width: 8),
                Text(
                    shortId(adresseFormatiert(
                        addCtl.text.replaceAll(RegExp(r'[\s\-]'), ''))),
                    style: doto(size: 13, weight: FontWeight.w600, color: p.muted, spacing: 0.8)),
              ]),
              const SizedBox(height: 6),
              Text(t('reqSentNote'), style: mono(size: 12, color: p.muted, height: 1.4)),
            ]),
          ),
        ],
        if (st.letzterFehler == 'adresseUngueltig') ...[
          const SizedBox(height: 12),
          Text(t('badAddress'), style: mono(size: 11.5, color: p.accLight, height: 1.5)),
        ],
        const Spacer(),
        Text(t('addFoot'), style: mono(size: 11, color: p.dim, height: 1.5)),
      ]),
    );
  }

  Widget smallBtn(String labelTxt, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.line)),
          child: Text(labelTxt.toUpperCase(), style: mono(size: 11, weight: FontWeight.w400, color: p.muted, spacing: 1.2)),
        ),
      );

  // ---- CHATS ----
  Widget chatsScreen() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(22, 11, 22, 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          h2(t('chats')),
          GestureDetector(
            onTap: () => setState(() { screen = 'add'; addCtl.clear(); reqSent = false; }),
            child: Container(
              width: 32, height: 32, alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.accent)),
              child: Text('+', style: TextStyle(color: p.accLight, fontSize: 18, height: 1)),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
          for (final k in st.offeneAnfragen) pendingCard(k),
          for (final id in contacts) contactRow(id),
          if (contacts.isEmpty && st.offeneAnfragen.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
              child: Text(t('noChats'), style: mono(size: 12, color: p.dim, height: 1.6)),
            ),
          Padding(padding: const EdgeInsets.fromLTRB(22, 16, 22, 16), child: Text(t('noNames'), style: mono(size: 11, color: p.dim, height: 1.5))),
        ]),
      ),
    ]);
  }

  Widget pendingCard(Contact k) => Container(
        margin: const EdgeInsets.fromLTRB(17, 8, 17, 11),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(shortId(adresseFormatiert(k.id)), style: doto(size: 13, weight: FontWeight.w600, color: p.tintInk, spacing: 0.8)),
          const SizedBox(height: 6),
          Text(t('wantsChat'), style: mono(size: 11.5, color: p.muted)),
          const SizedBox(height: 8),
          Row(children: [
            GestureDetector(
              onTap: () => acceptReq(k.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.accent)),
                child: Text(t('accept').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => st.anfrageAblehnen(k.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: p.line)),
                child: Text(t('decline').toUpperCase(), style: mono(size: 11, color: p.muted, spacing: 1.2)),
              ),
            ),
          ]),
        ]),
      );

  Widget contactRow(String id) {
    final list = st.verlaufVon(id);
    final letzte = list.isEmpty ? null : list.last;
    final last = letzte?.text ?? t('newContact');
    final time = letzte == null ? '' : zeitVon(letzte.timestamp);
    // Ungelesen: die letzte Nachricht kam von der Gegenstelle und diese
    // Unterhaltung ist gerade nicht offen.
    final unread = letzte != null && !letzte.isMine && chat != id;
    return GestureDetector(
      onTap: () => oeffneChat(id),
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        child: Row(children: [
          Identicon(id, 40, avp, 8),
          const SizedBox(width: 11),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(shortId(adresseFormatiert(id)), style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 0.8, height: 1.1)),
              const SizedBox(height: 3),
              Text(last, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono(size: 12, color: p.dim)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(time, style: mono(size: 10.5, color: p.dim)),
            const SizedBox(height: 6),
            Container(width: 8, height: 8, decoration: BoxDecoration(color: unread ? p.accent : Colors.transparent, shape: BoxShape.circle)),
          ]),
        ]),
      ),
    );
  }

  // ---- CHAT ----
  Widget chatScreen() {
    final cid = chat ?? c1;
    final hints = <String>[];
    if (settings['shot'] == true) hints.add(t('hintShot'));
    hints.add(t('hintEnc'));
    if (settings['eph'] != 'off') hints.add(t('hintEph') + ephLabel());
    final list = st.verlaufVon(cid);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(17, 8, 17, 8),
        child: Row(children: [
          iconBtn('‹', () => go('chats')),
          const SizedBox(width: 11),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => sheet = true),
              child: Row(children: [
                Identicon(cid, 32, avp, 8),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(shortId(cid), maxLines: 1, overflow: TextOverflow.ellipsis, style: doto(size: 14, weight: FontWeight.w600, color: p.ink, spacing: 0.8)),
                    Text(t('encDetails').toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1)),
                  ]),
                ),
              ]),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => sheet = true),
            child: Container(
              width: 30, height: 30, alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              child: Text('i', style: TextStyle(color: p.accLight, fontSize: 12)),
            ),
          ),
        ]),
      ),
      Container(height: 1, color: p.lineSoft),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.all(17),
          children: [
            Center(child: Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(hints.join(' · '), textAlign: TextAlign.center, style: mono(size: 10.5, color: p.dim, height: 1.5)))),
            for (int i = 0; i < list.length; i++) msgBubble(cid, list[i], i),
          ],
        ),
      ),
      Container(
        padding: const EdgeInsets.fromLTRB(17, 11, 17, 16),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: p.lineSoft))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            width: 36, height: 36, alignment: Alignment.center,
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
            child: Text('+', style: TextStyle(color: p.muted, fontSize: 16, height: 1)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 2),
              child: TextField(
                controller: draftCtl,
                style: mono(size: 13.5, color: p.ink),
                cursorColor: p.accent,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => send(),
                decoration: InputDecoration.collapsed(hintText: t('message'), hintStyle: mono(size: 13.5, color: p.dim)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: send,
            child: Container(
              height: 36, alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: p.accent)),
              child: Text(t('send').toUpperCase(), style: mono(size: 11, weight: FontWeight.w600, color: p.ink, spacing: 1.2)),
            ),
          ),
        ]),
      ),
    ]);
  }

  Widget msgBubble(String cid, Message m, int i) {
    final me = m.isMine;
    final time = zeitVon(m.timestamp);
    // Sprachnachrichten gibt es in Fassung 1 noch nicht — der Entwurf zeigte
    // sie, der Kern kennt nur Text. Lieber nichts anzeigen, als etwas
    // vorzutaeuschen — die Darstellung dafuer steht in der Versionsgeschichte
    // und kommt zurueck, sobald es Sprachnachrichten wirklich gibt.
    final bub = BoxDecoration(
      color: me ? p.tint : p.surf,
      borderRadius: me
          ? const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(8), bottomRight: Radius.circular(2))
          : const BorderRadius.only(topLeft: Radius.circular(8), topRight: Radius.circular(8), bottomLeft: Radius.circular(2), bottomRight: Radius.circular(8)),
      border: me ? Border.all(color: p.tintLine) : null,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(mainAxisAlignment: me ? MainAxisAlignment.end : MainAxisAlignment.start, children: [
        Flexible(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 252),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: bub,
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Align(alignment: Alignment.centerLeft, child: Text(m.text, style: TextStyle(fontSize: 13.5, color: p.ink, height: 1.4))),
              const SizedBox(height: 3),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(time, style: mono(size: 9.5, color: p.dim)),
                if (me) ...[
                  const SizedBox(width: 5),
                  // Ein Haken je erreichter Stufe: abgeschickt, zugestellt,
                  // gelesen. Solange sie noch beim Absender liegt, eine Uhr.
                  Text(
                    switch (m.status) {
                      MessageStatus.sending => '◷',
                      MessageStatus.sent => '✓',
                      MessageStatus.delivered => '✓✓',
                      MessageStatus.read => '✓✓',
                      MessageStatus.failed => '!',
                    },
                    style: mono(
                        size: 9.5,
                        color: m.status == MessageStatus.read
                            ? p.accLight
                            : p.dim),
                  ),
                ],
              ]),
            ]),
          ),
        ),
      ]),
    );
  }

  // ---- SETTINGS ----
  Widget settingsScreen() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 11, 22, 22),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        h2(t('settings')),
        const SizedBox(height: 17),
        label6(t('general')),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('language'), t('languageSub')),
          const SizedBox(height: 8),
          segmented(['en', 'de'], ['English', 'Deutsch'], lang, (v) => setState(() => lang = v)),
        ])),
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('appearance'), t('appearanceSub')),
          const SizedBox(height: 8),
          segmented(['dark', 'light'], [t('dark'), t('light')], mode, (v) => setState(() => mode = v)),
        ])),
        const SizedBox(height: 22),
        label6(t('access')),
        for (final k in ['bio', 'passkey', 'hw', 'totp']) ...[methodRow(k, statusMode: false), const SizedBox(height: 3)],
        Padding(padding: const EdgeInsets.fromLTRB(11, 3, 11, 0), child: Text(t('minOne'), style: mono(size: 10.5, color: p.dim))),
        const SizedBox(height: 22),
        label6(t('security')),
        toggleRow(t('screenshot'), t('screenshotSub'), settings['shot'] == true, () => setState(() => settings['shot'] = !(settings['shot'] as bool))),
        const SizedBox(height: 3),
        toggleRow(t('readReceipts'), t('readReceiptsSub'), settings['rec'] == true, () => setState(() => settings['rec'] = !(settings['rec'] as bool))),
        const SizedBox(height: 3),
        settingCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          settingHead(t('selfDestruct'), t('selfDestructSub')),
          const SizedBox(height: 8),
          segmented(['off', '1h', '24h', '7d'], [t('off'), t('h1'), t('h24'), t('d7')], settings['eph'] as String, (v) => setState(() => settings['eph'] = v)),
        ])),
        const SizedBox(height: 22),
        label6(t('identity')),
        GestureDetector(
          onTap: () => go('id'),
          child: settingCard(child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(t('myIdQr'), style: TextStyle(fontSize: 13.5, color: p.ink)),
            Text(shortId(meineAdresseAnzeige), style: doto(size: 12.5, weight: FontWeight.w600, color: p.dim, spacing: 0.8)),
          ])),
        ),
        const SizedBox(height: 3),
        settingCard(child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(t('fingerprint'), style: TextStyle(fontSize: 13.5, color: p.ink)),
          Text('b7d2 4e10 9af3', style: doto(size: 12.5, weight: FontWeight.w600, color: p.dim, spacing: 0.8)),
        ])),
        const SizedBox(height: 22),
        label6(t('emergency')),
        GestureDetector(
          onTap: () => setState(() => panic = true),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('panic'), style: TextStyle(fontSize: 13.5, color: p.tintInk)),
              Text(t('panicSub'), style: mono(size: 11, color: p.muted, height: 1.4)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget settingCard({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8)),
        child: child,
      );

  Widget settingHead(String title, String sub) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(fontSize: 13.5, color: p.ink)),
        Text(sub, style: mono(size: 11, color: p.dim)),
      ]);

  Widget segmented(List<String> keys, List<String> labels, String cur, ValueChanged<String> onPick) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: p.bg, borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        for (int i = 0; i < keys.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onPick(keys[i]),
              child: Container(
                margin: EdgeInsets.only(right: i < keys.length - 1 ? 3 : 0),
                padding: const EdgeInsets.symmetric(vertical: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: cur == keys[i] ? p.tint : Colors.transparent, borderRadius: BorderRadius.circular(4)),
                child: Text(labels[i], style: mono(size: 11, weight: FontWeight.w500, color: cur == keys[i] ? p.tintInk : p.muted)),
              ),
            ),
          ),
      ]),
    );
  }

  Widget toggleRow(String title, String sub, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: settingCard(
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: TextStyle(fontSize: 13.5, color: p.ink)),
                Text(sub, style: mono(size: 11, color: p.dim)),
              ]),
            ),
            const SizedBox(width: 12),
            AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 40, height: 22, padding: const EdgeInsets.all(2),
              alignment: on ? Alignment.centerRight : Alignment.centerLeft,
              decoration: BoxDecoration(color: on ? p.tint : p.surf, borderRadius: BorderRadius.circular(99), border: Border.all(color: on ? p.accent : p.line)),
              child: Container(width: 16, height: 16, decoration: BoxDecoration(color: on ? p.accLight : p.muted, shape: BoxShape.circle)),
            ),
          ]),
        ),
      );

  // ---- NAV ----
  Widget buildNav() {
    final active = screen == 'chat' ? 'chats' : screen;
    final items = [
      ['chats', t('navChats')],
      ['id', t('navId')],
      ['set', t('navSet')],
    ];
    return Container(
      decoration: BoxDecoration(color: p.navbg, border: Border(top: BorderSide(color: p.lineSoft))),
      child: SafeArea(
        top: false,
        child: Row(children: [
          for (final it in items)
            Expanded(
              child: GestureDetector(
                onTap: () => go(it[0]),
                child: Container(
                  padding: const EdgeInsets.only(top: 11, bottom: 15),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: active == it[0] ? p.accent : Colors.transparent, width: 2))),
                  alignment: Alignment.center,
                  child: Text(it[1].toUpperCase(), style: mono(size: 10.5, weight: FontWeight.w500, color: active == it[0] ? p.ink : p.dim, spacing: 1.2)),
                ),
              ),
            ),
        ]),
      ),
    );
  }

  // ---- OVERLAYS ----
  Widget scrim(Widget child, {Alignment align = Alignment.bottomCenter, VoidCallback? onTapOutside}) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onTapOutside,
        child: Container(
          color: p.scrim,
          alignment: align,
          child: GestureDetector(onTap: () {}, child: child),
        ),
      ),
    );
  }

  Widget sheetCard({required List<Widget> children}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: p.surf, borderRadius: const BorderRadius.vertical(top: Radius.circular(14)), border: Border.all(color: p.line)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget encSheet() {
    return scrim(
      onTapOutside: () => setState(() => sheet = false),
      sheetCard(children: [
        Center(child: Container(width: 36, height: 3, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(t('encryption'), size: 20),
        const SizedBox(height: 11),
        kvRow(t('protocol'), 'Double-Ratchet, X25519'),
        kvRow(t('sessionKey'), 'a3f9 21bd 77c4', mono2: true),
        kvRow(t('selfDestruct'), ephLabel()),
        kvRow(t('readReceipts'), settings['rec'] == true ? t('on') : t('off')),
        const SizedBox(height: 8),
        Container(height: 1, color: p.lineSoft),
        const SizedBox(height: 8),
        Text(t('verifyNote'), style: mono(size: 11, color: p.dim, height: 1.5)),
        const SizedBox(height: 11),
        outlineBtn(t('close'), () => setState(() => sheet = false), padding: const EdgeInsets.all(11)),
      ]),
    );
  }

  Widget kvRow(String k, String v, {bool mono2 = false}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Flexible(child: Text(k, style: mono(size: 12, color: p.muted))),
          const SizedBox(width: 16),
          Text(v, style: mono2 ? doto(size: 12, weight: FontWeight.w600, color: p.ink, spacing: 0.8) : TextStyle(fontSize: 12, color: p.ink)),
        ]),
      );

  Widget panicModal() {
    return scrim(
      align: Alignment.center,
      Container(
        margin: const EdgeInsets.all(22),
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(color: p.surf, borderRadius: BorderRadius.circular(14), border: Border.all(color: p.line)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          h2(t('panicTitle'), size: 20),
          const SizedBox(height: 11),
          Text(t('panicBody'), style: mono(size: 12.5, color: p.muted, height: 1.5)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: outlineBtn(t('cancel'), () => setState(() => panic = false), accent: false, padding: const EdgeInsets.all(11), weight: FontWeight.w400)),
            const SizedBox(width: 8),
            Expanded(child: outlineBtn(t('delete'), doWipe, padding: const EdgeInsets.all(11), textColor: p.tintInk)),
          ]),
        ]),
      ),
    );
  }

  Widget enrollModal() {
    final en = enroll!;
    final isTotp = en == 'totp';
    final title = en == 'bio' ? t('enrollBio') : en == 'passkey' ? t('enrollPasskey') : en == 'hw' ? t('enrollHw') : t('enrollTotp');
    final body = en == 'bio' ? t('enrollBioBody') : en == 'passkey' ? t('enrollPasskeyBody') : en == 'hw' ? t('enrollHwBody') : t('enrollTotpBody');
    final ready = codeCtl.text.length == 6;
    return scrim(
      onTapOutside: () {},
      sheetCard(children: [
        Center(child: Container(width: 36, height: 3, decoration: BoxDecoration(color: p.line, borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 11),
        h2(title, size: 20),
        const SizedBox(height: 11),
        Text(body, style: mono(size: 12, color: p.muted, height: 1.5)),
        const SizedBox(height: 11),
        if (!isTotp)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: p.tint, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.tintLine)),
            child: Row(children: [
              SizedBox(width: 34, height: 34, child: CircularProgressIndicator(strokeWidth: 1, color: p.accent)),
              const SizedBox(width: 11),
              Expanded(child: Text(t('waiting').toUpperCase(), style: mono(size: 11, weight: FontWeight.w500, color: p.tintInk, spacing: 1.4))),
            ]),
          ),
        if (isTotp) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t('secret').toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1.6)),
              const SizedBox(height: 4),
              Text('JBSW Y3DP EHPK 3PXP', style: doto(size: 15, weight: FontWeight.w600, color: p.ink, spacing: 1.4)),
            ]),
          ),
          const SizedBox(height: 8),
          Text(t('codeLabel').toUpperCase(), style: mono(size: 10, color: p.dim, spacing: 1.6)),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(color: p.surf2, borderRadius: BorderRadius.circular(8), border: Border.all(color: p.line)),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            child: TextField(
              controller: codeCtl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
              onChanged: (_) => setState(() {}),
              style: doto(size: 22, weight: FontWeight.w600, color: p.ink, spacing: 4),
              cursorColor: p.accent,
              decoration: InputDecoration.collapsed(hintText: '000000', hintStyle: doto(size: 22, weight: FontWeight.w600, color: p.dim, spacing: 4)),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: outlineBtn(t('cancel'), () => setState(() { enroll = null; codeCtl.clear(); }), accent: false, padding: const EdgeInsets.all(11), weight: FontWeight.w400)),
          if (isTotp) ...[
            const SizedBox(width: 8),
            Expanded(
              child: GestureDetector(
                onTap: confirmTotp,
                child: Container(
                  padding: const EdgeInsets.all(11),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: ready ? p.wash : Colors.transparent, borderRadius: BorderRadius.circular(8), border: Border.all(color: ready ? p.accent : p.line)),
                  child: Text(t('confirm').toUpperCase(), style: mono(size: 12, weight: FontWeight.w600, color: ready ? p.ink : p.dim, spacing: 1.2)),
                ),
              ),
            ),
          ],
        ]),
      ]),
    );
  }

  // ---- DEV JUMP ----
  void showDevJump() {
    final labels = jumpLabels[lang]!;
    const codes = ['onboard', 'secure', 'id', 'add', 'chats', 'chat', 'set'];
    showModalBottomSheet(
      context: context,
      backgroundColor: p.surf,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('SCREENS · DEV JUMP', style: mono(size: 10, weight: FontWeight.w600, color: p.dim, spacing: 1.6)),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (int i = 0; i < codes.length; i++)
              GestureDetector(
                onTap: () { Navigator.pop(ctx); setState(() { screen = codes[i]; chat ??= c1; sheet = false; panic = false; }); },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), border: Border.all(color: screen == codes[i] ? p.accent : p.line)),
                  child: Text(labels[i], style: mono(size: 11, weight: FontWeight.w500, color: screen == codes[i] ? p.accLight : p.muted)),
                ),
              ),
          ]),
        ]),
      ),
    );
  }
}
