// address_vectors.dart — Kreuzvektoren, erzeugt vom PYTHON-SERVER.
//
// Diese Werte stammen aus server/relay_server.py (encode_id). Der Dart-Test
// prueft damit, dass Client und Server dieselbe Adresse fuer denselben
// Schluessel berechnen. Weichen sie ab, koennte niemand jemanden adden —
// und der Fehler wuerde erst im Betrieb auffallen.
//
// Paare: (Schluessel hex, erwartete Adresse).
// Erzeugt, nicht von Hand abgetippt.

const List<(String, String)> addressCrossVectors = [
  ('9eec88b55d9295bb2ac6d35562a2ca5cebfe4e64feb234c2a8dde95d1b6cd2a2', 't3wirnk5skk3wkwg2nkwfiwkltv74tte72zdjqvi3xuv2g3m2kreqm75'),
  ('66e61081b2ab59e36767cdbccc4fa904d55a981e753ff52bcbda50adb0ebea9a', 'm3tbbansvnm6gz3hzw6myt5jatkvvga6ou77kk6l3jik3mhl5kng4xuf'),
  ('759a43cd338c11a386f89ef893c60b1268f6a7e69e0dac04a232321a483273bf', 'ownehtjtrqi2hbxyt34jhrqlcjupnj7gtyg2ybfcgizbusbsoo72oslh'),
  ('eaffcc915003cbef9c556e92ca3a8c0bc6fa8eb9a54ed9e4369cf92e8786872f', '5l74zekqapf67hcvn2jmuoumbpdpvdvzuvhntzbwtt4s5b4gq4xyusly'),
  ('c6a90cbf7eb4bc9574f9e606ce857c8ac0a7baee5abc8ecc91a5414311b521f2', 'y2uqzp36ws6jk5hz4ydm5bl4rlakpoxolk6i5teruvaugenvehzpr6go'),
  ('0fe72b50d1143170f38ad540e00d8d266d599bb7e1e8ee0a6e49bdf8270ea276', 'b7tswugrcqyxb44k2vaoadmnezwvtg5x4huo4ctojg67qjyouj3npvte'),
  ('586111355aa8ada49943b73631227b649c6d8d402838b6fdd755649f31cdc3f5', 'lbqrcnk2vcw2jgkdw43dcit3msog3dkafa4ln7oxkvsj6monyp2w42s3'),
  ('9fed6aef28b7789fb2a1520a078a9931a46f4ec3f1f58b50c767df5b39ea4ee4', 't7wwv3ziw54j7mvbkifapcuzggsg6twd6h2ywughm7pvwopkj3samagp'),
  ('709461f7a261249fd246c3bf3c62d0b51575b1005715d7ee467d86d198e863ff', 'ockgd55cmesj7usgyo7tyywqwukxlmiak4k5p3sgpwdndghimp76clgo'),
  ('2309dbf181946032a3711daa3e4d0d7dcab7365b8854ed4694f81aaedbacf327', 'eme5x4mbsrqdfi3rdwvd4tinpxflons3rbko2ruu7ank5w5m6mtyef52'),
  ('81c597aba40ba48f7f4b04262577fa14eadfa6bb9d7dee75bcb8052cca31293c', 'qhczpk5ebosi672laqtck572ctvn7jv3tv6645n4xacszsrrfe6c6dfu'),
  ('c039a50ab5a1cc7076b6ce67ac4ec05006b06d5acaa11ac82b14b703e84ca1a8', 'ya42kcvvuhgha5vwzzt2ytwakadla3k2zkqrvsblcs3qh2cmuguersoz'),
  ('0000000000000000000000000000000000000000000000000000000000000000', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaagm2d2'),
  ('ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff', '77777777777777777777777777777777777777777777777777727fqt'),
];
