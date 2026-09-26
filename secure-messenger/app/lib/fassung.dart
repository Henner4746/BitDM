// fassung.dart — welche Fassung diese App ist, und wie man Fassungen
// vergleicht.
//
// [appFassung] MUSS zur `version:` in pubspec.yaml passen (der Teil vor dem
// `+`). Das haelt test/fassung_test.dart fest: wer die pubspec hochzaehlt und
// diese Zeile vergisst, bekommt einen roten Test statt eines Update-Hinweises
// fuer die eigene, laengst installierte Fassung.

/// Die Fassung dieser App, ohne Baunummer.
const String appFassung = '1.9.0';

/// Vergleicht zwei Fassungen nach Semantic Versioning: negativ, wenn [a]
/// aelter ist als [b], positiv, wenn neuer, 0 bei gleich. Null, wenn eine der
/// beiden keine lesbare Fassung ist — dann ist nichts "neuer".
///
/// Zahl fuer Zahl, nicht als Text: "1.10.0" ist neuer als "1.9.0". Eine
/// Baunummer (`+19`) zaehlt nicht. Eine Vorabfassung (`2.0.0-beta`) ist
/// aelter als dieselbe ohne Zusatz.
int? vergleicheFassungen(String a, String b) {
  final x = _lies(a);
  final y = _lies(b);
  if (x == null || y == null) return null;
  for (var i = 0; i < 3; i++) {
    final d = x.zahlen[i].compareTo(y.zahlen[i]);
    if (d != 0) return d;
  }
  if (x.vorab == y.vorab) return 0;
  if (x.vorab == null) return 1;
  if (y.vorab == null) return -1;
  return x.vorab!.compareTo(y.vorab!);
}

/// Ob [fremd] neuer ist als [eigen]. Unlesbares ist nie neuer.
bool istNeuereFassung(String fremd, {String eigen = appFassung}) =>
    (vergleicheFassungen(fremd, eigen) ?? 0) > 0;

final _muster = RegExp(r'^(\d{1,6})(?:\.(\d{1,6}))?(?:\.(\d{1,6}))?'
    r'(?:-([0-9A-Za-z.-]{1,32}))?(?:\+[0-9A-Za-z.-]{1,32})?$');

({List<int> zahlen, String? vorab})? _lies(String s) {
  final m = _muster.firstMatch(s.trim());
  if (m == null) return null;
  return (
    zahlen: [
      for (var i = 1; i <= 3; i++) int.parse(m.group(i) ?? '0'),
    ],
    vorab: m.group(4),
  );
}
