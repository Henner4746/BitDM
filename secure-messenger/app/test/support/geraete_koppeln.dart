// geraete_koppeln.dart — ein zweites Geraet derselben Identitaet aufnehmen.
//
// SEIT DER GERAETEABMELDUNG (docs/GERAETEABMELDUNG.md) reicht es nicht mehr,
// dieselben zwoelf Woerter einzugeben: ein Geraet, das schon in der Liste
// steht, muss den Beitritt bestaetigen. Genau so, wie es ein Mensch tut —
// "Geraet hinzufuegen" zeigt einen Code, das neue Geraet bekommt ihn
// eingetippt — macht es diese Hilfe.

import 'package:bitdm/core/messenger_core.dart';
import 'package:bitdm/core/real_messenger_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'nutzer.dart';

/// [neu] hat die Woerter schon (restoreIdentity) und einmal verbunden, steht
/// also auf "Beitritt noetig". [vorhanden] ist verbunden und in der Liste.
/// Danach ist [neu] Mitglied und verbunden.
Future<void> koppele(Nutzer vorhanden, Nutzer neu) async {
  expect(vorhanden.core.geraeteStand, ListenStand.mitglied,
      reason: '${vorhanden.name} muss in der Liste stehen');
  if (neu.core.geraeteStand != ListenStand.beitrittNoetig) {
    await neu.core.connect();
  }
  expect(neu.core.geraeteStand, ListenStand.beitrittNoetig,
      reason: '${neu.name} steht noch nicht in der Liste');
  final code = await vorhanden.core.starteHinzufuegen();
  await neu.core.trittBei(code);
  expect(
      await Nutzer.warteBis(() =>
          neu.core.geraeteStand == ListenStand.mitglied &&
          neu.core.connectionState == ConnectionState.online),
      isTrue,
      reason: '${neu.name} wurde nicht aufgenommen '
          '(Stand ${neu.core.geraeteStand}, ${neu.core.connectionState})');
}
