#ifndef RUNNER_DATEI_KANAL_H_
#define RUNNER_DATEI_KANAL_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// Kanal "bitdm/dateien" unter Linux — dasselbe wie DateiKanal.kt unter
// Android und datei_kanal.cpp unter Windows. Die Gegenstelle ist
// lib/core/dateien.dart.
//
// "waehlen" und "oeffne" gibt es hier, "gibFrei" ist leer. "speichern" fehlt
// mit Absicht: ohne Antwort legt dateien.dart die Datei in den
// Download-Ordner und sagt, wohin.
//
// [fenster] ist das Fenster, ueber dem der Dialog steht; es wird nicht
// gehalten und muss den Kanal ueberleben.
FlMethodChannel* datei_kanal_neu(FlBinaryMessenger* messenger,
                                 GtkWindow* fenster);

#endif  // RUNNER_DATEI_KANAL_H_
