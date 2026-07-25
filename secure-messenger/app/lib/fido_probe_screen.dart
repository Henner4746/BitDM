// fido_probe_screen.dart â€” was kann dieser Stick?
//
// Ob ein bestimmter Sicherheitsschluessel die Rechenfunktion hmac-secret
// beherrscht, steht in keiner Produktbeschreibung verlaesslich. Die Erweiterung
// ist in CTAP2 optional, und Hersteller werben nicht damit.
//
// Statt zu raten fragt dieser Bildschirm den Stick selbst. Er schickt genau
// einen Befehl â€” authenticatorGetInfo â€”, der nichts anlegt, nichts aendert und
// keine PIN verlangt. Danach steht fest, ob sich die App-Sperre auf diesen
// Stick bauen laesst.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import 'core/fido/ctap.dart';
import 'core/fido/ctap_hid.dart';
import 'core/fido/ctap_nfc.dart';
import 'core/fido/usb_hid_geraet.dart';

class FidoProbeScreen extends StatefulWidget {
  const FidoProbeScreen({
    super.key,
    required this.titel,
    required this.anhalten,
    required this.keinNfc,
    required this.schliessen,
  });

  final String titel;
  final String anhalten;
  final String keinNfc;
  final String schliessen;

  @override
  State<FidoProbeScreen> createState() => _FidoProbeScreenState();
}

class _FidoProbeScreenState extends State<FidoProbeScreen> {
  String? _fehler;
  CtapInfo? _info;
  var _laeuft = false;

  @override
  void initState() {
    super.initState();
    _starteNfc();
  }

  Future<void> _starteNfc() async {
    if (await NfcManager.instance.checkAvailability() != NfcAvailability.enabled) {
      if (mounted) setState(() => _fehler = widget.keinNfc);
      return;
    }
    setState(() => _laeuft = true);
    await NfcManager.instance.startSession(
      pollingOptions: {NfcPollingOption.iso14443},
      onDiscovered: _lies,
    );
  }

  Future<void> _lies(NfcTag tag) async {
    try {
      final iso = IsoDepAndroid.from(tag);
      if (iso == null) {
        throw const FormatException(
            'Das ist kein Sicherheitsschluessel â€” die Karte spricht kein ISO-DEP.');
      }

      final transport = CtapNfcTransport((Uint8List apdu) => iso.transceive(apdu));
      await transport.verbinde();
      final info = await Ctap2(transport).holeInfo();

      if (mounted) setState(() { _info = info; _fehler = null; });
    } catch (e) {
      if (mounted) setState(() { _fehler = '$e'; _info = null; });
    } finally {
      await NfcManager.instance.stopSession();
      if (mounted) setState(() => _laeuft = false);
    }
  }

  /// Denselben Test ueber ein eingestecktes Kabel.
  ///
  /// USB spricht CTAPHID statt ISO-7816 â€” voellig andere Verpackung, derselbe
  /// Inhalt. Genau dafuer sitzt die Protokolllogik in ctap.dart und nicht in
  /// den Transporten.
  Future<void> _ueberUsb() async {
    setState(() { _fehler = null; _info = null; _laeuft = true; });
    try {
      final sticks = await UsbHidGeraet.liste();
      if (sticks.isEmpty) {
        throw const FormatException(
            'Kein Sicherheitsschluessel eingesteckt. Bei USB-C direkt anstecken — ueber einen Adapter erkennt Android ihn oft nicht.');
      }
      final geraet = await UsbHidGeraet.oeffne(name: sticks.first.name);
      final transport = CtapHidTransport(geraet);
      await transport.verbinde();
      final info = await Ctap2(transport).holeInfo();
      await transport.trenne();
      if (mounted) setState(() { _info = info; _fehler = null; });
    } catch (e) {
      if (mounted) setState(() { _fehler = ''; _info = null; });
    } finally {
      if (mounted) setState(() => _laeuft = false);
    }
  }

  @override
  void dispose() {
    NfcManager.instance.stopSession();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0C0E),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.titel.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 14, letterSpacing: 1.6)),
            const SizedBox(height: 20),

            Expanded(
              child: SingleChildScrollView(child: _inhalt()),
            ),

            const SizedBox(height: 12),
            GestureDetector(
              onTap: _laeuft ? null : _ueberUsb,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Text('STATTDESSEN PER KABEL',
                    style: TextStyle(color: Colors.white70, fontSize: 12, letterSpacing: 1.2)),
              ),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 13),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white38),
                ),
                child: Text(widget.schliessen.toUpperCase(),
                    style: const TextStyle(color: Colors.white, fontSize: 12, letterSpacing: 1.2)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _inhalt() {
    if (_fehler != null) {
      return Text(_fehler!,
          style: const TextStyle(color: Colors.orangeAccent, fontSize: 12.5, height: 1.6));
    }

    final info = _info;
    if (info == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_laeuft)
          const SizedBox(width: 20, height: 20,
              child: CircularProgressIndicator(strokeWidth: 1, color: Colors.white24)),
        const SizedBox(height: 16),
        Text(widget.anhalten,
            style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.7)),
      ]);
    }

    Widget zeile(String k, String v, {Color? farbe}) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(k.toUpperCase(),
                style: const TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 1.4)),
            const SizedBox(height: 3),
            Text(v, style: TextStyle(color: farbe ?? Colors.white, fontSize: 13, height: 1.4)),
          ]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Die Antwort auf die eine Frage, um die es geht â€” ganz oben.
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: info.kannHmacSecret
              ? const Color(0xFF10331F)
              : const Color(0xFF33201A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          info.kannHmacSecret
              ? 'hmac-secret: JA\n\nAuf diesen Stick laesst sich die App-Sperre bauen.'
              : 'hmac-secret: NEIN\n\nDieser Stick kann anmelden, aber nichts berechnen. '
                  'Fuer eine App-Sperre reicht das nicht.',
          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.6),
        ),
      ),
      const SizedBox(height: 20),
      zeile('Protokoll', info.versionen.join(', ')),
      zeile('Erweiterungen',
          info.erweiterungen.isEmpty ? '(keine)' : info.erweiterungen.join('\n')),
      zeile('Eigenschaften',
          info.eigenschaften.entries.map((e) => '${e.key}: ${e.value}').join('\n')),
      zeile('Kennung (AAGUID)',
          info.aaguid.map((b) => b.toRadixString(16).padLeft(2, '0')).join()),
    ]);
  }
}
