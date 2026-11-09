#include "geheime_ablage.h"

#include <flutter/standard_method_codec.h>

#include <cstring>
#include <string>

// SEIT 09.11.2026, mit dem Kopierknopf fuer die zwoelf Woerter.
//
// Ohne diese Datei kopierte Windows ueber Flutters eigene Zwischenablage, und
// die nimmt jeder Verlauf mit: Win+V zeigt die Woerter noch nach dem Leeren,
// und mit "Geraeteuebergreifend synchronisieren" lagen sie im Microsoft-Konto.
// Dagegen gibt es drei Formate, die Passwortmanager (KeePass, KeePassXC,
// 1Password) neben den Text legen:
//
//   ExcludeClipboardContentFromMonitorProcessing — irgendein Inhalt; dann
//       uebernehmen Verlauf und Ablage-Ueberwacher den Eintrag nicht.
//   CanIncludeInClipboardHistory = 0 — nicht in den Verlauf (Win+V).
//   CanUploadToCloudClipboard = 0 — nicht in die Cloud-Zwischenablage.
//
// Beschrieben unter "Clipboard Formats" in der Win32-Doku
// (dataxchg/clipboard-formats, Abschnitt "Cloud Clipboard and Clipboard
// History Formats").

using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::wstring Utf16AusUtf8(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int laenge = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         text.data(),
                                         static_cast<int>(text.size()), nullptr, 0);
  if (laenge <= 0) return std::wstring();
  std::wstring ergebnis(laenge, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), ergebnis.data(), laenge);
  return ergebnis;
}

const EncodableValue* Feld(const EncodableValue* argumente, const char* name) {
  const auto* karte = std::get_if<EncodableMap>(argumente);
  if (karte == nullptr) return nullptr;
  auto it = karte->find(EncodableValue(name));
  return it == karte->end() ? nullptr : &it->second;
}

// Oeffnet die Ablage fuer [fenster]. Haelt sie gerade ein anderes Programm
// offen (Ablage-Ueberwacher tun das kurz nach jeder Aenderung), schlaegt
// OpenClipboard fehl — dann ein paar Mal kurz nachfassen statt aufzugeben.
bool Oeffne(HWND fenster) {
  for (int versuch = 0; versuch < 5; ++versuch) {
    if (OpenClipboard(fenster)) return true;
    Sleep(20);
  }
  return false;
}

// Legt [groesse] Bytes ab [daten] im Format [format] ab. Die Ablage muss
// offen sein. Danach gehoert der Speicher dem System.
bool Lege(UINT format, const void* daten, size_t groesse) {
  if (format == 0) return false;
  HGLOBAL speicher = GlobalAlloc(GMEM_MOVEABLE, groesse);
  if (speicher == nullptr) return false;
  void* ziel = GlobalLock(speicher);
  if (ziel == nullptr) {
    GlobalFree(speicher);
    return false;
  }
  std::memcpy(ziel, daten, groesse);
  GlobalUnlock(speicher);
  if (SetClipboardData(format, speicher) == nullptr) {
    GlobalFree(speicher);
    return false;
  }
  return true;
}

// Ein DWORD in einem registrierten Format.
bool LegeZahl(const wchar_t* name, DWORD wert) {
  return Lege(RegisterClipboardFormatW(name), &wert, sizeof(wert));
}

}  // namespace

bool GeheimeAblage::Kopiere(HWND fenster, const std::wstring& text) {
  if (text.empty() || !Oeffne(fenster)) return false;
  bool ok = EmptyClipboard() != FALSE;
  // ERST DIE AUSSCHLUESSE, DANN DER TEXT. Ausgewertet wird zwar erst nach
  // CloseClipboard, aber so steht nie ein Augenblick lang Text ohne sie da.
  ok = ok &&
       LegeZahl(L"ExcludeClipboardContentFromMonitorProcessing", 1) &&
       LegeZahl(L"CanIncludeInClipboardHistory", 0) &&
       LegeZahl(L"CanUploadToCloudClipboard", 0) &&
       Lege(CF_UNICODETEXT, text.c_str(), (text.size() + 1) * sizeof(wchar_t));
  // Ging etwas schief, lieber gar nichts in der Ablage als die Woerter ohne
  // Schutz. Die Dart-Seite kopiert dann ueber Flutter — das ist eine
  // bewusste Entscheidung dort, nicht ein Zufall hier.
  if (!ok) EmptyClipboard();
  CloseClipboard();
  return ok;
}

bool GeheimeAblage::Leere(HWND fenster) {
  if (!Oeffne(fenster)) return false;
  const bool ok = EmptyClipboard() != FALSE;
  CloseClipboard();
  return ok;
}

GeheimeAblage::GeheimeAblage(flutter::BinaryMessenger* messenger,
                             std::function<HWND()> fenster)
    : fenster_(std::move(fenster)) {
  kanal_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "bitdm/ablage", &flutter::StandardMethodCodec::GetInstance());
  kanal_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& aufruf,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> ergebnis) {
        const std::string& methode = aufruf.method_name();
        if (methode == "kopiere") {
          const EncodableValue* wert = Feld(aufruf.arguments(), "text");
          const auto* text = wert ? std::get_if<std::string>(wert) : nullptr;
          ergebnis->Success(EncodableValue(
              text != nullptr && Kopiere(fenster_(), Utf16AusUtf8(*text))));
        } else if (methode == "leere") {
          ergebnis->Success(EncodableValue(Leere(fenster_())));
        } else {
          ergebnis->NotImplemented();
        }
      });
}
