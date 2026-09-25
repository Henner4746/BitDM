#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

// Aeltere Windows-SDKs kennen den Wert noch nicht (winuser.h, ab 10.0.19041).
#ifndef WDA_EXCLUDEFROMCAPTURE
#define WDA_EXCLUDEFROMCAPTURE 0x00000011
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // SCREENSHOT-SPERRE AUCH AUF WINDOWS (seit 25.09.2026). Bis dahin gab es
  // den Kanal nur auf Android, und die App zeigte "Screenshot-Schutz aktiv",
  // ohne dass hier etwas geschuetzt war — auch Einmal-Bilder nicht.
  // WDA_EXCLUDEFROMCAPTURE (ab Windows 10 2004) nimmt das Fenster aus
  // Screenshots, Aufnahmen und Bildschirmfreigabe heraus; aeltere Fassungen
  // koennen nur WDA_MONITOR (schwarzes Rechteck). Klappt beides nicht, sagt
  // die Antwort false, und die Oberflaeche verspricht nichts.
  fenster_kanal_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "bitdm/fenster",
      &flutter::StandardMethodCodec::GetInstance());
  fenster_kanal_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& aufruf,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> ergebnis) {
        if (aufruf.method_name() != "setzeScreenshotSperre") {
          ergebnis->NotImplemented();
          return;
        }
        bool an = false;
        if (const auto* karte = std::get_if<flutter::EncodableMap>(aufruf.arguments())) {
          auto it = karte->find(flutter::EncodableValue("an"));
          if (it != karte->end()) {
            if (const auto* wert = std::get_if<bool>(&it->second)) an = *wert;
          }
        }
        HWND fenster = GetHandle();
        BOOL ok;
        if (an) {
          ok = SetWindowDisplayAffinity(fenster, WDA_EXCLUDEFROMCAPTURE);
          if (!ok) ok = SetWindowDisplayAffinity(fenster, WDA_MONITOR);
        } else {
          ok = SetWindowDisplayAffinity(fenster, WDA_NONE);
        }
        // Beim Ausschalten meldet "true" das Gelingen, nicht einen Schutz.
        ergebnis->Success(flutter::EncodableValue(an ? (ok != FALSE) : false));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
