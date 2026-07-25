// WEGWERF-APP. Misst, ob und wie die Nahverbindung auf echten Geraeten
// funktioniert. Danach loeschen.
//
// SIE GEHOERT NICHT ZU BitDM und soll es auch nicht. Der Grund steht im
// Manifest: fuer Wi-Fi Direct braucht es unterhalb von Android 13 den
// Standortzugriff, und der waere in einem Messenger, der Metadaten vermeidet,
// die invasivste Berechtigung ueberhaupt. Ob es sie wirklich braucht, soll
// dieser Test zeigen — bevor sie irgendwo dauerhaft steht.
//
// FUENF FRAGEN, DIE ER BEANTWORTEN MUSS:
//   1. Wird ein BLE-Advertisement mit 6 Byte Nutzlast gesehen, wie schnell?
//   2. Baut Wi-Fi Direct eine Verbindung auf, wie lange dauert es?
//   3. Kommt dabei auf der Gegenseite ein Dialog? (Das sieht der Mensch.)
//   4. Reisst die bestehende WLAN-Verbindung ab?
//   5. Wie schnell sind ein paar hundert Byte drueben?

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _kanal = MethodChannel('nahtest/kanal');
const _ereignisse = EventChannel('nahtest/ereignisse');

void main() => runApp(const NahTestApp());

class NahTestApp extends StatelessWidget {
  const NahTestApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'BitDM Nah-Test',
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(useMaterial3: true),
        home: const TestSeite(),
      );
}

class TestSeite extends StatefulWidget {
  const TestSeite({super.key});

  @override
  State<TestSeite> createState() => _TestSeiteState();
}

class _TestSeiteState extends State<TestSeite> {
  final _zeilen = <String>[];
  final _rollen = ScrollController();
  final _code = TextEditingController(text: '1234');
  StreamSubscription<dynamic>? _abo;

  /// Wie viele Geraete die P2P-Suche gefunden hat — fuer die Verbinden-Knoepfe.
  int _gefundene = 0;

  @override
  void initState() {
    super.initState();
    _abo = _ereignisse.receiveBroadcastStream().listen((e) {
      final text = '$e';
      // Die Zahl der gefundenen Geraete aus der Meldung ziehen, statt einen
      // zweiten Kanal dafuer zu bauen. Wegwerfcode darf so etwas.
      final treffer = RegExp(r'^P2P: (\d+) Geraet').firstMatch(text);
      setState(() {
        if (treffer != null) _gefundene = int.parse(treffer.group(1)!);
        _zeilen.add('${_uhr()}  $text');
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_rollen.hasClients) {
          _rollen.jumpTo(_rollen.position.maxScrollExtent);
        }
      });
    });
    _sag('Bereit. Auf BEIDEN Telefonen dieselbe Reihenfolge:');
    _sag('  1. "BLE aussenden" und "BLE suchen" — auf beiden');
    _sag('  2. "Wi-Fi Direct starten" — auf beiden');
    _sag('  3. "Verbinden" — nur auf EINEM');
  }

  String _uhr() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:'
        '${n.minute.toString().padLeft(2, '0')}:'
        '${n.second.toString().padLeft(2, '0')}.'
        '${n.millisecond ~/ 100}';
  }

  void _sag(String s) => setState(() => _zeilen.add('${_uhr()}  $s'));

  Future<void> _ruf(String methode, [Map<String, Object?>? args]) async {
    try {
      await _kanal.invokeMethod<Object?>(methode, args);
    } on PlatformException catch (e) {
      _sag('FEHLER bei $methode: ${e.code} — ${e.message}');
    }
  }

  @override
  void dispose() {
    _abo?.cancel();
    _rollen.dispose();
    _code.dispose();
    super.dispose();
  }

  Color _farbe(String zeile) {
    if (zeile.contains('FEHLER') ||
        zeile.contains('FEHLGESCHLAGEN') ||
        zeile.contains('ABGELEHNT') ||
        zeile.contains('verweigert')) {
      return Colors.redAccent;
    }
    if (zeile.contains('GEFUNDEN') || zeile.contains('VERBUNDEN')) {
      return Colors.greenAccent;
    }
    if (zeile.contains('>>>')) return Colors.amberAccent;
    return Colors.white70;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('BitDM Nah-Test')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Row(children: [
              SizedBox(
                width: 96,
                child: TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Code',
                      isDense: true,
                      border: OutlineInputBorder()),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Auf beiden Telefonen derselbe Code — dann verwechseln sich '
                  'zwei Testlaeufe im selben Raum nicht.',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonal(
                onPressed: () =>
                    _ruf('bleWerben', {'code': int.tryParse(_code.text) ?? 0}),
                child: const Text('1a  BLE aussenden'),
              ),
              FilledButton.tonal(
                onPressed: () => _ruf('bleSuchen'),
                child: const Text('1b  BLE suchen'),
              ),
              FilledButton.tonal(
                onPressed: () => _ruf('p2pStart'),
                child: const Text('2  Wi-Fi Direct starten'),
              ),
              for (var i = 0; i < _gefundene; i++)
                FilledButton(
                  onPressed: () => _ruf('p2pVerbinden', {'index': i}),
                  child: Text('3  Verbinden #${i + 1}'),
                ),
              OutlinedButton(
                onPressed: () => _ruf('wlanZustand'),
                child: const Text('WLAN pruefen'),
              ),
              OutlinedButton(
                onPressed: () => _ruf('stopp'),
                child: const Text('Alles stoppen'),
              ),
              OutlinedButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _zeilen.join('\n')));
                  _sag('Protokoll kopiert.');
                },
                child: const Text('Protokoll kopieren'),
              ),
            ]),
          ]),
        ),
        const Divider(height: 1),
        Expanded(
          child: Container(
            color: Colors.black,
            width: double.infinity,
            child: ListView.builder(
              controller: _rollen,
              padding: const EdgeInsets.all(10),
              itemCount: _zeilen.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: SelectableText(
                  _zeilen[i],
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 11.5,
                    height: 1.35,
                    color: _farbe(_zeilen[i]),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
