#include "datei_kanal.h"

#include <glib/gstdio.h>
#include <sys/stat.h>

#include <cstring>

// SEIT 17.10.2026. Bis dahin gab es den Kanal nur unter Android; am PC war
// "Datei anhaengen" zu sehen und tat nichts (siehe datei_kanal.cpp).

namespace {

struct DateiKanal {
  GtkWindow* fenster;
  // Ob gerade ein Auswahldialog offen ist. Zwei gleichzeitig gibt es nicht,
  // und ohne Sperre bliebe der erste Aufruf fuer immer ohne Antwort.
  gboolean waehlt;
};

// Was zwischen dem Oeffnen des Dialogs und seiner Antwort aufgehoben wird.
struct Wartend {
  DateiKanal* kanal;
  FlMethodCall* aufruf;
};

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

gboolean schalter_feld(FlValue* argumente, const char* name) {
  if (argumente == nullptr || fl_value_get_type(argumente) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }
  FlValue* wert = fl_value_lookup_string(argumente, name);
  return wert != nullptr && fl_value_get_type(wert) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(wert);
}

void waehlen_fertig(GtkNativeDialog* dialog, gint antwort, gpointer daten) {
  Wartend* wartend = static_cast<Wartend*>(daten);
  wartend->kanal->waehlt = FALSE;

  g_autoptr(FlValue) ergebnis = nullptr;
  const gchar* fehler = nullptr;
  if (antwort == GTK_RESPONSE_ACCEPT) {
    g_autofree gchar* pfad =
        gtk_file_chooser_get_filename(GTK_FILE_CHOOSER(dialog));
    GStatBuf info;
    // dart:io spricht Pfade als UTF-8. Ein Name in einer anderen Kodierung
    // liesse sich von dort gar nicht oeffnen.
    if (pfad == nullptr || !g_utf8_validate(pfad, -1, nullptr) ||
        g_stat(pfad, &info) != 0 || !S_ISREG(info.st_mode)) {
      fehler = "unlesbar";
    } else {
      g_autofree gchar* name = g_path_get_basename(pfad);
      ergebnis = fl_value_new_map();
      fl_value_set_string_take(ergebnis, "pfad", fl_value_new_string(pfad));
      fl_value_set_string_take(ergebnis, "name", fl_value_new_string(name));
      fl_value_set_string_take(ergebnis, "groesse",
                               fl_value_new_int(static_cast<int64_t>(info.st_size)));
      fl_value_set_string_take(ergebnis, "zettel", fl_value_new_string(""));
      fl_value_set_string_take(ergebnis, "kopiert", fl_value_new_bool(FALSE));
    }
  }
  if (fehler != nullptr) {
    fl_method_call_respond_error(wartend->aufruf, fehler,
                                 "Die gewaehlte Datei laesst sich nicht lesen",
                                 nullptr, nullptr);
  } else {
    fl_method_call_respond_success(wartend->aufruf, ergebnis, nullptr);
  }
  g_object_unref(wartend->aufruf);
  g_free(wartend);
  g_object_unref(dialog);
}

// Der Auswahldialog. Antwortet spaeter, aus [waehlen_fertig] — kein eigener
// gtk_dialog_run, der die Hauptschleife verschachtelt.
//
// GtkFileChooserNative und nicht GtkFileChooserDialog: in einer Sandbox
// (Flatpak, Snap) geht es dann ueber das Portal, sonst ist es der Dialog von
// GTK. Gewaehlt wird die Originaldatei, kopiert wird nichts.
void waehlen(DateiKanal* kanal, FlMethodCall* aufruf) {
  if (kanal->waehlt) {
    fl_method_call_respond_error(aufruf, "laeuft",
                                 "Es ist schon eine Auswahl offen", nullptr,
                                 nullptr);
    return;
  }
  GtkFileChooserNative* dialog = gtk_file_chooser_native_new(
      nullptr, kanal->fenster, GTK_FILE_CHOOSER_ACTION_OPEN, nullptr, nullptr);
  gtk_file_chooser_set_local_only(GTK_FILE_CHOOSER(dialog), TRUE);
  gtk_native_dialog_set_modal(GTK_NATIVE_DIALOG(dialog), TRUE);

  Wartend* wartend = g_new0(Wartend, 1);
  wartend->kanal = kanal;
  wartend->aufruf = FL_METHOD_CALL(g_object_ref(aufruf));
  kanal->waehlt = TRUE;
  g_signal_connect(dialog, "response", G_CALLBACK(waehlen_fertig), wartend);
  gtk_native_dialog_show(GTK_NATIVE_DIALOG(dialog));
}

// Reicht eine empfangene Datei an das Programm weiter, das der Desktop dafuer
// vorsieht. false heisst wie unter Android: nichts konnte sie oeffnen.
//
// [als_text]: HTML, SVG, Skripte gehen an das Programm fuer text/plain statt
// an den Browser — dort liefen Skripte und luden von fremden Servern nach,
// mit der IP-Adresse des Empfaengers. Welche das sind, entscheidet
// lib/core/dateien.dart. Ausfuehren kann hier nichts: die entschluesselte
// Kopie hat kein Ausfuehrungsrecht.
gboolean oeffne(DateiKanal* kanal, const gchar* pfad, gboolean als_text) {
  if (pfad == nullptr || !g_file_test(pfad, G_FILE_TEST_IS_REGULAR)) return FALSE;
  g_autoptr(GError) fehler = nullptr;
  if (als_text) {
    g_autoptr(GAppInfo) programm =
        g_app_info_get_default_for_type("text/plain", FALSE);
    if (programm == nullptr) return FALSE;
    g_autoptr(GFile) datei = g_file_new_for_path(pfad);
    GList liste = {datei, nullptr, nullptr};
    return g_app_info_launch(programm, &liste, nullptr, &fehler);
  }
  g_autofree gchar* uri = g_filename_to_uri(pfad, nullptr, &fehler);
  if (uri == nullptr) return FALSE;
  return gtk_show_uri_on_window(kanal->fenster, uri, GDK_CURRENT_TIME, &fehler);
}

void bearbeite(FlMethodChannel* channel, FlMethodCall* aufruf, gpointer daten) {
  DateiKanal* kanal = static_cast<DateiKanal*>(daten);
  const gchar* methode = fl_method_call_get_name(aufruf);
  FlValue* argumente = fl_method_call_get_args(aufruf);
  if (strcmp(methode, "waehlen") == 0) {
    waehlen(kanal, aufruf);
  } else if (strcmp(methode, "gibFrei") == 0) {
    // Nichts festgehalten, nichts freizugeben.
    fl_method_call_respond_success(aufruf, nullptr, nullptr);
  } else if (strcmp(methode, "oeffne") == 0) {
    g_autoptr(FlValue) ging = fl_value_new_bool(
        oeffne(kanal, text_feld(argumente, "pfad"),
               schalter_feld(argumente, "alsText")));
    fl_method_call_respond_success(aufruf, ging, nullptr);
  } else {
    fl_method_call_respond_not_implemented(aufruf, nullptr);
  }
}

}  // namespace

FlMethodChannel* datei_kanal_neu(FlBinaryMessenger* messenger,
                                 GtkWindow* fenster) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(messenger, "bitdm/dateien",
                                                   FL_METHOD_CODEC(codec));
  DateiKanal* kanal = g_new0(DateiKanal, 1);
  kanal->fenster = fenster;
  fl_method_channel_set_method_call_handler(channel, bearbeite, kanal, g_free);
  return channel;
}
