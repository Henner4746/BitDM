#ifndef RUNNER_GEHEIME_ABLAGE_H_
#define RUNNER_GEHEIME_ABLAGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// Kanal "bitdm/ablage" auf Windows — dasselbe wie GeheimeAblage.kt unter
// Android. Die Gegenstelle ist lib/core/geheime_ablage.dart.
//
// "kopiere" legt den Text so in die Zwischenablage, dass der Verlauf (Win+V)
// und die Synchronisation ueber das Microsoft-Konto ihn nicht uebernehmen.
// "leere" leert sie ganz. Wann geleert wird, entscheidet die Dart-Seite: am
// Rechner darf die App die Ablage auch im Hintergrund lesen.
class GeheimeAblage {
 public:
  // [fenster] liefert das Fenster, dem die Ablage danach gehoert.
  GeheimeAblage(flutter::BinaryMessenger* messenger,
                std::function<HWND()> fenster);

  // Legt [text] mit den Ausschluss-Formaten in die Ablage. Oeffentlich, damit
  // sich der Win32-Teil ohne Flutter pruefen laesst.
  static bool Kopiere(HWND fenster, const std::wstring& text);

  // Leert die Ablage.
  static bool Leere(HWND fenster);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> kanal_;
  std::function<HWND()> fenster_;
};

#endif  // RUNNER_GEHEIME_ABLAGE_H_
