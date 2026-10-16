#ifndef RUNNER_DATEI_KANAL_H_
#define RUNNER_DATEI_KANAL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <functional>
#include <memory>

// Kanal "bitdm/dateien" auf Windows — dasselbe wie DateiKanal.kt unter
// Android. Die Gegenstelle ist lib/core/dateien.dart.
//
// "waehlen" und "oeffne" gibt es hier, "gibFrei" ist leer (der Pfad ist die
// Originaldatei, es wird nichts festgehalten). "speichern" fehlt mit Absicht:
// ohne Antwort legt dateien.dart die Datei in den Download-Ordner und sagt,
// wohin.
class DateiKanal {
 public:
  // [fenster] liefert das Fenster, ueber dem die Dialoge stehen.
  DateiKanal(flutter::BinaryMessenger* messenger,
             std::function<HWND()> fenster);

 private:
  void Bearbeite(
      const flutter::MethodCall<flutter::EncodableValue>& aufruf,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> ergebnis);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> kanal_;
  std::function<HWND()> fenster_;

  // Ob gerade ein Auswahldialog offen ist. Show() dreht eine eigene
  // Nachrichtenschleife, in der ein zweiter Aufruf ankommen kann.
  bool waehlt_ = false;
};

#endif  // RUNNER_DATEI_KANAL_H_
