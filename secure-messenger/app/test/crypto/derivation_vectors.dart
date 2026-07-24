// derivation_vectors.dart — Kreuzvektoren aus einer UNABHAENGIGEN Nachrechnung.
//
// Erzeugt mit Python: hashlib.pbkdf2_hmac fuer den BIP39-Seed, eine direkte
// RFC-5869-Implementierung fuer HKDF, und libxeddsa (ueber das xeddsa-Paket)
// fuer den oeffentlichen Schluessel. Also durchgaengig ANDERE Bibliotheken als
// auf der Dart-Seite — genau deshalb ist der Vergleich aussagekraeftig.
//
// Stimmen beide ueberein, ist die gesamte Kette von zwoelf Woertern bis zur
// fertigen Adresse in zwei unabhaengigen Implementierungen bestaetigt.
//
// Tupel: (Wortfolge, Identitaets-Privatschluessel, oeffentlicher Schluessel,
//         Datenbankschluessel, Adresse) — alle Schluessel hex.
// Erzeugt, nicht von Hand abgetippt.

const List<(String, String, String, String, String)> derivationCrossVectors = [
  (
    'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
    '988d67781eb76ee4e8048c2f6595d05ed68765635d0a9bde27734a0e2976f965',
    'fad52adf45d91f41e97e436e033b2fb29cf52f0863587d0d6c2bfb011c4a1633',
    '4b8c52c1d0ddf889333ba19d63298d14930e9d69936be0441b5f41ce674988cb',
    '7lksvx2f3epud2l6inxagozpwkopklyimnmh2dlmfp5qchckcyzslecj',
  ),
  (
    'legal winner thank year wave sausage worth useful legal winner thank yellow',
    '18ed6bc82e4f6f86e3e9a30044c65ec57145a03203c5bfbde8575d7ccc97c269',
    '0cd190cdd417a66db14eb40383b36ea44c8dc6ecbe1708d31acd603310ce3e50',
    'fd199adc087f6e60780ecdc81ee0a6aed22c28cac5e09c1ce018460e90c36491',
    'btizbtouc6tg3mkowqbyhm3ourgi3rxmxylqruy2zvqdgegohzilezfs',
  ),
  (
    'letter advice cage absurd amount doctor acoustic avoid letter advice cage above',
    'f826275ed8dee81e3b61363f1667616aebf2d285beacbf4ac45c7062f3c8b45b',
    '33ab08644d9b1a42423b988ad01a6452a18a3b07d3948443932afd163946812c',
    '0c1af38280348308ee599ab77b643a7f730413e1dfc268f3c94496d24aeeb1cd',
    'govqqzcntmneeqr3tcfnagtekkqyuoyh2okiiq4tfl6rmokgqewed44n',
  ),
  (
    'zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo wrong',
    '5874ec0f7ae4147c81d014985109c630b145bee908833e8cd568fbb2a6968e41',
    '48384aa3a710aaec29a6f4ed1892c69db71a47756830f7e3c0d287d49961953b',
    '643b4203377ff62cd7d05c98e26c72c6d298b009b8cda297f5133b4512e61ce0',
    'ja4evi5hccvoykng6twrrewgtw3rur3vnayppy6a2kd5jglbsu5t4vrr',
  ),
];
