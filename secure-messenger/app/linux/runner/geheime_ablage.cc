#include "geheime_ablage.h"

#include <cstring>

// SEIT 09.11.2026, mit dem Kopierknopf fuer die zwoelf Woerter.
//
// Flutters eigene Zwischenablage (gtk_clipboard_set_text) bietet nur Text an,
// und Verlaufsprogramme wie Klipper (KDE) merken sich jeden Text — auch, wenn
// die App die Ablage nach einer Minute wieder leert. Passwortmanager legen
// deshalb ein zweites Ziel daneben: "x-kde-passwordManagerHint" mit dem
// Inhalt "secret". Klipper und andere Verlaeufe lassen solche Eintraege aus.
//
// Ueber gtk_clipboard_set_with_data: die Ablage gehoert dann dieser App, und
// der Text wird erst ausgeliefert, wenn jemand einfuegt. Uebernimmt ein
// anderes Programm die Ablage, ruft GTK [vergiss] — dann wird der Text hier
// sofort ueberschrieben und freigegeben.

namespace {

// Was gerade in der Ablage steht, solange sie dieser App gehoert. Statisch:
// GTK kann [liefere] und [vergiss] rufen, solange die App lebt, auch nachdem
// der Kanal schon weg ist.
gchar* g_inhalt = nullptr;

// Die "info"-Werte der beiden Ziele.
constexpr guint kText = 1;
constexpr guint kHinweis = 2;

GtkClipboard* ablage() {
  return gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
}

void liefere(GtkClipboard* clipboard, GtkSelectionData* auswahl, guint info,
             gpointer daten) {
  if (g_inhalt == nullptr) return;
  if (info == kHinweis) {
    static const guchar kGeheim[] = "secret";
    gtk_selection_data_set(auswahl, gtk_selection_data_get_target(auswahl), 8,
                           kGeheim, 6);
  } else {
    gtk_selection_data_set_text(auswahl, g_inhalt, -1);
  }
}

void vergiss(GtkClipboard* clipboard, gpointer daten) {
  if (g_inhalt == nullptr) return;
  // Ueberschreiben, bevor der Speicher zurueckgeht: g_free raeumt nicht.
  memset(g_inhalt, 0, strlen(g_inhalt));
  g_free(g_inhalt);
  g_inhalt = nullptr;
}

gboolean kopiere(const gchar* text) {
  if (text == nullptr || *text == '\0') return FALSE;
  GtkTargetList* liste = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_text_targets(liste, kText);
  gtk_target_list_add(liste, gdk_atom_intern_static_string(
                                 "x-kde-passwordManagerHint"),
                      0, kHinweis);
  gint anzahl = 0;
  GtkTargetEntry* ziele = gtk_target_table_new_from_list(liste, &anzahl);
  gtk_target_list_unref(liste);
  // ERST UEBERNEHMEN, DANN MERKEN. Gehoerte die Ablage schon dieser App, ruft
  // GTK hier drin [vergiss] fuer den alten Inhalt.
  const gboolean ok = gtk_clipboard_set_with_data(
      ablage(), ziele, anzahl, liefere, vergiss, nullptr);
  gtk_target_table_free(ziele, anzahl);
  if (ok) g_inhalt = g_strdup(text);
  return ok;
}

gboolean leere() {
  if (g_inhalt == nullptr) return FALSE;  // gehoert schon jemand anderem
  // Gibt die Ablage frei; GTK ruft dabei [vergiss].
  gtk_clipboard_clear(ablage());
  return TRUE;
}

const gchar* text_feld(FlValue* argumente, const char* name) {
  if (argumente == nullptr || fl_value_get_type(argumente) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* wert = fl_value_lookup_string(argumente, name);
  if (wert == nullptr || fl_value_get_type(wert) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(wert);
}

void bearbeite(FlMethodChannel* channel, FlMethodCall* aufruf, gpointer daten) {
  const gchar* methode = fl_method_call_get_name(aufruf);
  if (strcmp(methode, "kopiere") == 0) {
    g_autoptr(FlValue) ging = fl_value_new_bool(
        kopiere(text_feld(fl_method_call_get_args(aufruf), "text")));
    fl_method_call_respond_success(aufruf, ging, nullptr);
  } else if (strcmp(methode, "leere") == 0) {
    g_autoptr(FlValue) ging = fl_value_new_bool(leere());
    fl_method_call_respond_success(aufruf, ging, nullptr);
  } else {
    fl_method_call_respond_not_implemented(aufruf, nullptr);
  }
}

}  // namespace

FlMethodChannel* geheime_ablage_neu(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(messenger, "bitdm/ablage",
                                                   FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, bearbeite, nullptr,
                                            nullptr);
  return channel;
}
