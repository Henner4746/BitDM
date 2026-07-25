"""signature_vectors.py — echte XEdDSA-Signaturen aus dem Dart-Client.

Erzeugt mit libsignal_protocol_dart 0.8.2 ueber Curve.calculateSignature, ueber
der Nachricht bytes(range(32)). Paare: (Curve25519-Public-Key, Signatur), beide
base64.

WARUM DIESE DATEI EXISTIERT
Der Relay prueft XEdDSA. Ein reiner Python-Test kann das NICHT belastbar
abdecken: libxeddsa erzwingt beim Signieren ein Vorzeichenbit von 0 (so steht es
in der XEdDSA-Spezifikation), waehrend libsignal das natuerliche Vorzeichen
behaelt und in das oberste Bit der Signatur legt. Ein Python-Test wuerde also
nur Signaturen einer Sorte erzeugen — und genau daran ist der urspruengliche
Test gescheitert: er signierte mit demselben falschen Vorzeichenbit, mit dem der
Server prueffte. 15/15 gruen, waehrend echte Clients zur Haelfte abgewiesen
worden waeren.

Die Haelfte der Vektoren unten hat das Vorzeichenbit gesetzt, die andere nicht.
Nur so faellt ein Rueckfall in den alten Fehler auf.
"""

MESSAGE = bytes(range(32))

# (public_key_b64, signature_b64)
DART_SIGNATURES = [
    ("ln9nOKyN4WCOYfJ5NrRE0Rib4kknoIjfE6dO1+WsMmI=",
     "V7hWrHzjTTattaB6qyZPYwgvPogbBGdhOUGg3bx8QLT/i4XrpuISZwPoOPU5uxAL62Jg0zODiN+J3gEIj0IMgg=="),
    ("A9Jjd0r3XgbizI5l6AIiVj/UqVUZIaGTCHb8z1LvTG8=",
     "7xhxInDpdp1IXsYjmrIakdyfyFJN+nu88HqwUfOvoztjNfIPmkv13N3jq60Apd5S1uBYmyfkzULqw/vS4y6Sgw=="),
    ("XdC1jH5nX4j9c+FxvzEqR9Z7KZpkb08O8DNQRxlkDn0=",
     "vklGrHtW1UCvO6ts5SO2JOL6uN65X249QFxWg07lo3TJEq7fbQns2SQl6uMsmaKI/vpcnxo5+/9/eyRHMsxtiQ=="),
    ("TJBJEPkU6UYGGj/+eyVItimabyD/zPcU+JQz56/HqGE=",
     "SE1k89TMYYnkxWJ3TQ+6nz6BojNCoE9HHtBGfXtylZDoghCrqzmG5nVRiH0JbizgDC8LF46xHFFg7zGhl4zQgg=="),
    ("ZPFe9PA2ZwWKS5WPPsRiYCOGh1Uga9bBYGs4OISiGTE=",
     "GTQTe4YvVK/E2a3jKzHmgp2lQeaFD95jG4qJJwZhtSoefetutKvFlXZYfaJ2Oha2p6S/+FYndeCEDL+WHK2lCQ=="),
    ("lWhBjDh1OiVLiOND4kl/HjL6DpXo+YZ7KVbiWPxnciU=",
     "kUb7vxLlck4w00N02Zn0owSAuYyXjIrBh9hN7DL2qFOEJguzKY/yGQ3KeWIrYxKevk2CtU7lvkRaK9lN2Z3ZCw=="),
    ("qyIbUOgyrpbe9PLuP218FS9jKajeWYp0nnHLwC4A7z8=",
     "Bph/KN3WF+cS5D6SNHdnmT1WpRh2M0xWtF7RXl4xJ3f+PlCPlhfQY4o3KQicLB/z1xBvuz4TKk/J6Zy/SOntCw=="),
    ("OR/1MuyIKDg1+zO2YVJfT2gP4mjif9WrO3uuN+1M+U0=",
     "7BXPqfq2utPb7YXFx/O6hofUfUDskGZVAoRBw5nb+VYGoEzoF7phI5D6gSilf+f3UfpbbShsFTJ2G5VyAjmwAA=="),
]
