#!/usr/bin/env python3
"""namen_pruefen.py — Gate G3 der Aufteilung von main.dart.

In einer `extension _X on _HomeState` gewinnt ein gleichnamiger Top-Level-Name
STILL gegen das Mitglied der Klasse (lexikalischer Bereich vor implizitem
`this`). Und ein Extension-Mitglied, das wie ein geerbtes Mitglied von State,
WidgetsBindingObserver oder TickerProviderStateMixin heisst, wird nie
aufgerufen: dann gewinnt das geerbte. Beides gaebe keinen Compilerfehler.

Prueft alle Mitglieder von _HomeState und seiner Extensions (lib/oberflaeche/
home.dart und home/*.dart, sonst lib/main.dart) gegen:
  - Top-Level-Namen in lib/ und in den Paketen flutter, path_provider,
    url_launcher (Pfade aus .dart_tool/package_config.json),
  - Top-Level-Funktionen aus dart:core/dart:async,
  - geerbte Mitglieder von State & Co.

Aufruf im Ordner secure-messenger/app:  python tool/namen_pruefen.py
Ausgang 0 ohne Kollision, sonst 1.
"""
import json
import os
import re
import sys
from urllib.parse import unquote, urlparse

MITGLIED = re.compile(
    r"^  (?:static\s+)?(?:late\s+)?(?:final\s+|const\s+)?"
    r"(?:[A-Za-z_][\w<>?,\s\[\]\(\)]*?\s+)?(?:get\s+|set\s+)?([A-Za-z_]\w*)\s*(\(|=>|=|;|\{|,|<)")
TOP = re.compile(
    r"^(?:external\s+)?(?:final\s+|const\s+|late\s+final\s+|late\s+)?"
    r"(?:[A-Za-z_][\w<>?,\s\[\]]*?\s+)?(?:get\s+|set\s+)?([a-z_][A-Za-z0-9_]*)\s*(\(|=|;|=>|<)")
KEIN_TOP = ("import", "export", "part", "library", "class", "abstract", "enum", "mixin",
            "extension", "typedef", "sealed", "base", "final class", "interface", "if",
            "return", "switch")
DART_CORE = {"print", "identical", "identityHashCode", "unawaited", "runZoned",
             "runZonedGuarded", "scheduleMicrotask"}
GEERBT = {
    # State
    "setState", "initState", "dispose", "build", "didUpdateWidget", "didChangeDependencies",
    "reassemble", "deactivate", "activate", "context", "mounted", "widget",
    "debugFillProperties", "toString", "toStringShort", "hashCode", "runtimeType", "noSuchMethod",
    "toDiagnosticsNode",
    # WidgetsBindingObserver
    "didChangeAppLifecycleState", "didChangeMetrics", "didChangeLocales",
    "didChangeTextScaleFactor", "didChangePlatformBrightness", "didHaveMemoryPressure",
    "didPopRoute", "didPushRoute", "didPushRouteInformation", "didRequestAppExit",
    "didChangeAccessibilityFeatures", "didChangeViewFocus", "handleStartBackGesture",
    "handleUpdateBackGestureProgress", "handleCommitBackGesture", "handleCancelBackGesture",
    # TickerProviderStateMixin
    "createTicker",
}


def mitglieder(dateien):
    namen = set()
    for d in dateien:
        drin = False
        for z in open(d, encoding="utf-8").read().split("\n"):
            if z.startswith(("class _HomeState ", "extension _")):
                drin = True
                continue
            if drin and z.startswith("}"):
                drin = False
                continue
            if drin and z.startswith("  ") and not z.startswith("   "):
                s = z.strip()
                if s.startswith(("//", "@", "}", ")")):
                    continue
                m = MITGLIED.match(z)
                if m:
                    namen.add(m.group(1))
    return namen


def paketwurzeln():
    cfg = json.load(open(".dart_tool/package_config.json", encoding="utf-8"))
    basis = os.path.abspath(".dart_tool")
    for p in cfg["packages"]:
        if p["name"] not in ("flutter", "path_provider", "url_launcher"):
            continue
        uri = p["rootUri"]
        pfad = unquote(urlparse(uri).path) if uri.startswith("file:") else os.path.join(basis, uri)
        if os.name == "nt" and re.match(r"^/[A-Za-z]:", pfad):
            pfad = pfad[1:]
        yield os.path.join(pfad, p.get("packageUri", "lib/"))


def top_namen(wurzeln, eigene):
    """Top-Level-Namen; private (`_x`) nur aus der EIGENEN Bibliothek — aus
    jeder anderen sind sie unsichtbar und koennen nichts verdecken."""
    eigene = {os.path.abspath(e) for e in eigene}
    funde = {}
    for w in wurzeln:
        for d, _, dateien in os.walk(w):
            for f in dateien:
                if not f.endswith(".dart"):
                    continue
                pfad = os.path.join(d, f)
                for z in open(pfad, encoding="utf-8", errors="replace").read().split("\n"):
                    if not z or z[0] in " \t/}@)*" or z.startswith(KEIN_TOP):
                        continue
                    m = TOP.match(z)
                    if m:
                        if m.group(1).startswith("_") and os.path.abspath(pfad) not in eigene:
                            continue
                        funde.setdefault(m.group(1), set()).add(pfad)
    return funde


def main():
    home = os.path.join("lib", "oberflaeche", "home.dart")
    if os.path.exists(home):
        teile = os.path.join("lib", "oberflaeche", "home")
        dateien = [home] + ([os.path.join(teile, f) for f in sorted(os.listdir(teile))
                             if f.endswith(".dart")] if os.path.isdir(teile) else [])
    else:
        dateien = [os.path.join("lib", "main.dart")]
    namen = mitglieder(dateien)
    top = top_namen(["lib", *paketwurzeln()], dateien)
    fehler = []
    for n in sorted(namen):
        if n in top:
            fehler.append(f"{n}: Top-Level in {', '.join(sorted(top[n]))[:200]}")
        if n in DART_CORE:
            fehler.append(f"{n}: Top-Level in dart:core/async")
    # Geerbte Namen zaehlen nur fuer Mitglieder, die in einer Extension stehen.
    in_extension = mitglieder(dateien[1:]) if len(dateien) > 1 else set()
    for n in sorted(in_extension & GEERBT):
        fehler.append(f"{n}: heisst wie ein geerbtes Mitglied, steht aber in einer Extension")
    print(f"{len(namen)} Mitglieder geprueft ({len(in_extension)} in Extensions)")
    for f in fehler:
        print("  KOLLISION", f)
    return 1 if fehler else 0


if __name__ == "__main__":
    sys.exit(main())
