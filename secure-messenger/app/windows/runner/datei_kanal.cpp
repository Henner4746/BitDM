#include "datei_kanal.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <string>

#include "utils.h"

// SEIT 17.10.2026. Bis dahin gab es den Kanal nur unter Android. Am PC war
// "Datei anhaengen" zu sehen, und ein Druck darauf tat nichts: waehlen() fing
// die MissingPluginException und gab still null zurueck. Ebenso "Sicherung
// einspielen" und "Oeffnen" bei einem empfangenen Anhang (dort mit der
// falschen Auskunft, keine App koenne die Datei oeffnen).

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

namespace {

// Unter dieser Kennung merkt sich Windows, was der Nutzer bei Nachfragen zu
// Anhaengen aus BitDM entschieden hat. Fest, nicht pro Lauf neu.
// {6B1D5E0A-3C2F-4E57-9A8D-2F4B7C1E9D30}
constexpr GUID kBitdmAnhaenge = {
    0x6b1d5e0a, 0x3c2f, 0x4e57, {0x9a, 0x8d, 0x2f, 0x4b, 0x7c, 0x1e, 0x9d, 0x30}};

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

std::wstring TextFeld(const EncodableValue* argumente, const char* name) {
  const EncodableValue* wert = Feld(argumente, name);
  const auto* text = wert ? std::get_if<std::string>(wert) : nullptr;
  return text ? Utf16AusUtf8(*text) : std::wstring();
}

bool SchalterFeld(const EncodableValue* argumente, const char* name) {
  const EncodableValue* wert = Feld(argumente, name);
  const auto* schalter = wert ? std::get_if<bool>(wert) : nullptr;
  return schalter != nullptr && *schalter;
}

// Der Auswahldialog des Systems. Antwortet mit derselben Karte wie
// DateiKanal.kt, mit null bei Abbruch.
//
// KEINE KOPIE: der Pfad ist die Originaldatei, und dart:io liest sie direkt.
// Der Grund fuer den eigenen Kanal unter Android (drei Gigabyte nicht
// doppelt) gilt hier genauso.
void Waehle(HWND fenster, flutter::MethodResult<EncodableValue>& ergebnis) {
  ComPtr<IFileOpenDialog> dialog;
  if (FAILED(CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
    ergebnis.Error("keineAuswahl", "Kein Dateidialog auf diesem Rechner");
    return;
  }
  FILEOPENDIALOGOPTIONS optionen = 0;
  dialog->GetOptions(&optionen);
  // FOS_DONTADDTORECENT: was an eine Nachricht geht, gehoert nicht in die
  // Liste "Zuletzt verwendet" des Explorers.
  dialog->SetOptions(optionen | FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST |
                     FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR | FOS_DONTADDTORECENT);

  const HRESULT gezeigt = dialog->Show(fenster);
  if (gezeigt == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    ergebnis.Success();
    return;
  }
  ComPtr<IShellItem> eintrag;
  PWSTR roh = nullptr;
  if (FAILED(gezeigt) || FAILED(dialog->GetResult(&eintrag)) ||
      FAILED(eintrag->GetDisplayName(SIGDN_FILESYSPATH, &roh))) {
    ergebnis.Error("keineAuswahl", "Der Dateidialog lieferte keinen Pfad");
    return;
  }
  const std::wstring pfad(roh);
  CoTaskMemFree(roh);

  WIN32_FILE_ATTRIBUTE_DATA info{};
  if (!GetFileAttributesExW(pfad.c_str(), GetFileExInfoStandard, &info)) {
    ergebnis.Error("unlesbar", "Die gewaehlte Datei laesst sich nicht lesen");
    return;
  }
  const int64_t groesse =
      (static_cast<int64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
  // Der Name aus dem Pfad und nicht der Anzeigename: der laesst die Endung
  // weg, wenn der Explorer bekannte Endungen ausblendet.
  const size_t schnitt = pfad.find_last_of(L"\\/");
  const std::wstring name =
      schnitt == std::wstring::npos ? pfad : pfad.substr(schnitt + 1);

  ergebnis.Success(EncodableValue(EncodableMap{
      {EncodableValue("pfad"), EncodableValue(Utf8FromUtf16(pfad.c_str()))},
      {EncodableValue("name"), EncodableValue(Utf8FromUtf16(name.c_str()))},
      {EncodableValue("groesse"), EncodableValue(groesse)},
      {EncodableValue("zettel"), EncodableValue(std::string())},
      {EncodableValue("kopiert"), EncodableValue(false)},
  }));
}

// Reicht eine empfangene Datei an das Programm weiter, das Windows dafuer
// vorsieht. Rueckgabe wie unter Android: false heisst "nichts konnte sie
// oeffnen".
//
// ERST DURCH DIE ANHANGPRUEFUNG VON WINDOWS. IAttachmentExecute ist dieselbe
// Stelle, die Browser und Mailprogramme benutzen: sie markiert die Datei als
// "aus dem Internet" (Zone.Identifier) und laesst den Virenscanner darueber.
// Mit der Markierung fragt Windows beim Oeffnen eines Programms, Skripts oder
// einer Verknuepfung nach, Office oeffnet in der geschuetzten Ansicht, und
// SmartScreen greift. Ohne sie liefe eine geschickte "rechnung.exe" auf einen
// Doppelklick einfach los. Die Datei kommt von einem Kontakt, aber was er
// schickt, hat er selbst vielleicht nur weitergereicht.
//
// [als_text]: fuer Inhalte, die ein Betrachter ausfuehrt statt zeigt (HTML,
// SVG, Skripte). Sie gehen an das Programm fuer .txt — wie unter Android als
// text/plain. Welche das sind, entscheidet lib/core/dateien.dart.
bool Oeffne(HWND fenster, const std::wstring& pfad, const std::wstring& name,
            bool als_text) {
  if (pfad.empty() || GetFileAttributesW(pfad.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }
  ComPtr<IAttachmentExecute> pruefung;
  if (FAILED(CoCreateInstance(CLSID_AttachmentServices, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&pruefung)))) {
    // Ohne Pruefung nicht oeffnen. Die gibt es seit Windows XP SP2; fehlt
    // sie, stimmt am Rechner etwas Grundsaetzliches nicht.
    return false;
  }
  pruefung->SetClientGuid(kBitdmAnhaenge);
  pruefung->SetClientTitle(L"BitDM");
  pruefung->SetLocalPath(pfad.c_str());
  if (!name.empty()) pruefung->SetFileName(name.c_str());
  // "about:internet" steht fuer die Internetzone: BitDM kennt keine
  // Herkunftsadresse, und eine Nachricht von aussen ist genau das.
  pruefung->SetSource(L"about:internet");
  if (FAILED(pruefung->SaveWithUI(fenster))) {
    // Gesperrt — von einer Richtlinie oder vom Virenscanner. Windows hat
    // den Grund schon selbst angezeigt; eine zweite Meldung von BitDM ("keine
    // App kann das oeffnen") waere falsch.
    return true;
  }

  SHELLEXECUTEINFOW aufruf{};
  aufruf.cbSize = sizeof(aufruf);
  aufruf.hwnd = fenster;
  aufruf.lpFile = pfad.c_str();
  aufruf.nShow = SW_SHOWNORMAL;
  if (als_text) {
    aufruf.fMask |= SEE_MASK_CLASSNAME;
    aufruf.lpClass = L".txt";
  }
  if (ShellExecuteExW(&aufruf)) return true;
  // Im Dialog "Wie soll die Datei geoeffnet werden?" abgebrochen: das war
  // eine Entscheidung, kein fehlendes Programm.
  return GetLastError() == ERROR_CANCELLED;
}

}  // namespace

DateiKanal::DateiKanal(flutter::BinaryMessenger* messenger,
                       std::function<HWND()> fenster)
    : fenster_(std::move(fenster)) {
  kanal_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "bitdm/dateien", &flutter::StandardMethodCodec::GetInstance());
  kanal_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& aufruf,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> ergebnis) {
        Bearbeite(aufruf, std::move(ergebnis));
      });
}

void DateiKanal::Bearbeite(
    const flutter::MethodCall<EncodableValue>& aufruf,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> ergebnis) {
  const std::string& methode = aufruf.method_name();
  if (methode == "waehlen") {
    if (waehlt_) {
      ergebnis->Error("laeuft", "Es ist schon eine Auswahl offen");
      return;
    }
    waehlt_ = true;
    Waehle(fenster_(), *ergebnis);
    waehlt_ = false;
  } else if (methode == "gibFrei") {
    // Nichts festgehalten, nichts freizugeben.
    ergebnis->Success();
  } else if (methode == "oeffne") {
    const EncodableValue* argumente = aufruf.arguments();
    ergebnis->Success(EncodableValue(
        Oeffne(fenster_(), TextFeld(argumente, "pfad"),
               TextFeld(argumente, "name"), SchalterFeld(argumente, "alsText"))));
  } else {
    ergebnis->NotImplemented();
  }
}
