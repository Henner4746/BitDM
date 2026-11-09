#ifndef RUNNER_GEHEIME_ABLAGE_H_
#define RUNNER_GEHEIME_ABLAGE_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Kanal "bitdm/ablage" unter Linux — dasselbe wie GeheimeAblage.kt unter
// Android und geheime_ablage.cpp unter Windows. Die Gegenstelle ist
// lib/core/geheime_ablage.dart.
//
// "kopiere" bietet den Text zusammen mit dem Hinweis
// "x-kde-passwordManagerHint: secret" an; "leere" gibt die Ablage frei,
// solange sie noch dieser App gehoert. Wann geleert wird, entscheidet die
// Dart-Seite.
FlMethodChannel* geheime_ablage_neu(FlBinaryMessenger* messenger);

#endif  // RUNNER_GEHEIME_ABLAGE_H_
