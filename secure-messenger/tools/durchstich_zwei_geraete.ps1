# durchstich_zwei_geraete.ps1 — eine Nachricht von einem Telefon zum anderen.
#
# WAS DIESER LAUF BEWEIST, das kein Einheitentest beweisen kann: dass zwei
# echte Installationen auf echtem Android ueber einen echten Server eine
# Sitzung aufbauen und Nachrichten austauschen, in beide Richtungen.
# Kontaktanfrage, Bestaetigen, PQXDH (seit 2.0.0), Double Ratchet, WebSocket —
# alles am Stueck, nichts nachgebaut.
#
# ZWEI EMULATOREN BRAUCHEN RUND 11 GB. Vorher pruefen, sonst faellt der
# zweite mitten im Hochfahren um, und die Meldung deutet auf alles Moegliche
# ausser auf Speichermangel.
#
# WELCHER SERVER: ohne -Lokal der echte relay.bitdm.net. Jeder Lauf
# hinterlaesst dort ZWEI Karteileichen; ihre Adressen stehen am Ende im
# Bericht.
#
# MIT -Lokal ein Relay auf diesem Rechner. Die App kennt keine Einstellung
# "eigener Server" mehr (docs/EIGENER-SERVER.md), der Relay steht deshalb
# fest im Bau:
#   flutter build apk --release --dart-define=BITDM_RELAY=http://10.0.2.2:8611
#                               --dart-define=BITDM_LAGER=http://10.0.2.2:8612
# und der Relay laeuft vorher, mit Kyber-Pflicht wie nach dem Stichtag:
#   BITDM_KYBER_PFLICHT=1 BITDM_TEST_RELAY_PORT=8611 BITDM_TEST_LAGER_PORT=8612
#     python server/tools/testaufbau.py
# Die Emulatoren starten dann OHNE Namensaufloesung: selbst eine falsch
# gebaute APK erreicht relay.bitdm.net nicht. Seit 2.0.0 ist das der Weg,
# solange der echte Relay noch kein Kyber kennt.

[CmdletBinding()]
param(
  [string]$AvdA = 'BitDM_B',
  [string]$AvdB = 'BitDM_C',
  [int]$PortA = 5554,
  [int]$PortB = 5556,
  [string]$Apk = "$PSScriptRoot\..\app\build\app\outputs\flutter-apk\app-release.apk",
  [string]$Text = 'Durchstich',
  # Was B zurueckschreibt. Ein Wort: `adb shell input text` zerlegt Leerzeichen.
  [string]$Antwort = 'Zurueck',
  # Relay auf diesem Rechner, Emulatoren ohne DNS. Siehe oben.
  [switch]$Lokal,
  # Geraete, die nicht hier laufen: adb-Namen wie 127.0.0.1:5555, wenn die
  # Emulatoren auf dem Mini-PC stehen und ihr adb-Port per SSH hergeleitet
  # ist (ssh -L 5555:127.0.0.1:5555, dann adb connect). Nur mit -Weiter.
  [string]$ZielA = '',
  [string]$ZielB = '',
  # Emulatoren laufen schon, nicht neu starten.
  [switch]$Weiter,
  [switch]$LassStehen
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\geraet.ps1"

$script:start = Get-Date
function Schritt($t) { Write-Host "`n[$([int]((Get-Date) - $script:start).TotalSeconds)s] $t" -ForegroundColor Cyan }
function Sag($t) { Write-Host "  $t" -ForegroundColor DarkGray }
function Gut($t) { Write-Host "  OK  $t" -ForegroundColor Green }
function Schlecht($t) { Write-Host "  FEHLER  $t" -ForegroundColor Red }

$A = if ($ZielA) { $ZielA } else { "emulator-$PortA" }
$B = if ($ZielB) { $ZielB } else { "emulator-$PortB" }

# Schreibt in die OFFENE Unterhaltung und schickt ab.
#
# Das Schreibfeld steht links neben SEND und hat, solange es leer ist,
# keinen eigenen Knoten. Also SEND suchen und daneben tippen.
function Sende([string]$Wer, [string]$Inhalt) {
  $send = Finde-Knoten (Lies-Oberflaeche) '^SEND$'
  if (-not $send) { throw "${Wer}: kein Knopf SEND" }
  Adb shell input tap ($send.X - 500) $send.Y | Out-Null
  Start-Sleep -Milliseconds 700
  Adb shell input text $Inhalt | Out-Null
  Start-Sleep -Milliseconds 700

  # SEND NEU SUCHEN. Mit offener Tastatur schrumpft der sichtbare Bereich, und
  # der Knopf sitzt tausend Pixel weiter oben. Der erste Versuch tippte auf
  # die alte Stelle, traf die Leiste darunter, und der Text blieb im Feld
  # stehen — ohne dass irgendetwas nach einem Fehler aussah.
  $send = Finde-Knoten (Lies-Oberflaeche) '^SEND$'
  if (-not $send) { throw "${Wer}: SEND ist nach der Eingabe verschwunden" }
  Tippe $send
  Start-Sleep -Seconds 3
  if ((Lies-Oberflaeche) -notmatch [regex]::Escape($Inhalt)) {
    throw "${Wer}: die Nachricht steht nicht im eigenen Verlauf"
  }
}

# Wartet, bis [Inhalt] auf dem Bildschirm steht; oeffnet notfalls die
# Unterhaltung mit [Kurz], falls er in der Liste steht und nicht drin.
function Warte-AufNachricht([string]$Inhalt, [string]$Kurz, [int]$Sekunden = 90) {
  $ende = (Get-Date).AddSeconds($Sekunden)
  while ((Get-Date) -lt $ende) {
    if ((Lies-Oberflaeche 3) -match [regex]::Escape($Inhalt)) { return $true }
    Start-Sleep -Seconds 2
  }
  $k = Finde-Knoten (Lies-Oberflaeche) $Kurz
  if ($k) {
    Tippe $k
    Start-Sleep -Seconds 2
    return ((Lies-Oberflaeche) -match [regex]::Escape($Inhalt))
  }
  return $false
}

try {
  if (-not $Weiter) {
    Schritt 'zwei Emulatoren starten'
    $frei = (Get-CimInstance Win32_PerfRawData_PerfOS_Memory).AvailableMBytes / 1024
    if ($frei -lt 12) {
      throw ("nur {0:N1} GB verfuegbar — zwei Emulatoren brauchen rund 11 GB" -f $frei)
    }
    Starte-Emulator $AvdA $PortA -OhneDns:$Lokal
    Starte-Emulator $AvdB $PortB -OhneDns:$Lokal
    foreach ($z in $A, $B) {
      Nimm-Geraet $z
      if (-not (Warte-AufBereitschaft 300)) { throw "$z wurde nicht bereit" }
    }
    Gut 'beide bereit'
  }

  Schritt 'App aufspielen und einrichten'
  $adr = @{}
  foreach ($z in $A, $B) {
    Nimm-Geraet $z
    Setze-App-Neu $Apk
    Starte-App
    $adr[$z] = Lege-Identitaet-An
    Sag "$z  $($adr[$z])"
  }
  Gut 'zwei Identitaeten'

  # ── A fragt B ──────────────────────────────────────────────────────────
  Schritt 'A schickt B eine Kontaktanfrage'
  Nimm-Geraet $A
  $k = Warte-AufText '^CHATS$' 30
  if (-not $k) { throw 'A: kein Reiter CHATS' }
  Tippe $k
  # Das Plus sitzt in derselben Semantik-Einheit wie die Ueberschrift
  # ("CHATS/CONNECTED/+"), es gibt also keinen eigenen Knoten dafuer. Oben
  # rechts tippen ist hier kein Rueckfall auf Koordinaten, sondern die einzige
  # Moeglichkeit.
  #
  # ABER IN dp GERECHNET, nicht in Bildpunkten. Fest eingetragene 1200 lagen
  # auf einem 1080 breiten Bildschirm neben dem Fenster; gemeldet wurde
  # daraufhin "der Bildschirm ADD CONTACT kam nicht".
  #
  # SEIT DEM HINWEIS FUER BILDSCHIRMLESER hat das Plus einen eigenen Knoten
  # ("Add contact"). Den zuerst nehmen; die Ueberschrift nur noch als Rueckfall
  # fuer aeltere Fassungen.
  $xml = Lies-Oberflaeche
  $plus = Finde-Knoten $xml '^Add contact'
  if ($plus) {
    Tippe $plus
  } else {
    $kopf = Finde-Rahmen $xml 'CHATS.*\+'
    if (-not $kopf) { throw 'A: weder "Add contact" noch die Ueberschrift mit dem Plus' }
    Adb shell input tap ($kopf.Rechts - (Dp 26)) ($kopf.Oben + (Dp 18)) | Out-Null
  }
  Start-Sleep -Seconds 2
  $k = Warte-AufText '^SEND REQUEST$' 20
  if (-not $k) { throw 'A: der Bildschirm ADD CONTACT kam nicht' }

  # Das Eingabefeld liegt zwischen der Beschriftung BITDM ID und den Knoepfen
  # und hat, solange es leer ist, keinen eigenen Knoten.
  $marke = Finde-Knoten (Lies-Oberflaeche) '^BITDM ID$' -Alle
  if (-not $marke) { throw 'A: keine Beschriftung BITDM ID' }
  Adb shell input tap $marke.X ($marke.Y + 116) | Out-Null
  Start-Sleep -Milliseconds 700
  Adb shell input text $adr[$B] | Out-Null
  Adb shell input keyevent 4 | Out-Null
  Start-Sleep -Milliseconds 700

  $xml = Lies-Oberflaeche
  if ($xml -notmatch [regex]::Escape($adr[$B])) { throw 'A: die Adresse steht nicht im Feld' }
  Tippe (Finde-Knoten $xml '^SEND REQUEST$')
  Start-Sleep -Seconds 3
  if ((Lies-Oberflaeche) -notmatch 'PENDING') { throw 'A: die Anfrage wurde nicht abgeschickt' }
  Gut 'Anfrage raus'

  # ZURUECK ZUR LISTE. Ohne diesen Schritt bleibt A auf ADD CONTACT stehen —
  # und dort steht die Adresse des Gegenuebers ebenfalls ("U2OH…" unter
  # PENDING). Die Suche nach der Unterhaltung fand sie also, tippte auf einen
  # nicht klickbaren Knoten, und alles Weitere landete im Adressfeld. Der Lauf
  # meldete danach "abgeschickt", weil der Nachrichtentext tatsaechlich auf
  # dem Bildschirm stand: im falschen Feld.
  $k = Finde-Knoten (Lies-Oberflaeche) '^‹$'
  if (-not $k) { throw 'A: kein Zurueck-Pfeil' }
  Tippe $k
  Start-Sleep -Seconds 2

  # ── B bestaetigt ───────────────────────────────────────────────────────
  Schritt 'B bestaetigt'
  Nimm-Geraet $B
  $k = Warte-AufText '^CHATS$' 30
  if ($k) { Tippe $k }
  $k = Warte-AufText '^ACCEPT$' 60
  if (-not $k) { throw 'B: die Anfrage kam nicht an' }
  Gut 'die Anfrage ist bei B angekommen'
  Tippe $k
  Start-Sleep -Seconds 3

  # ── A schreibt ─────────────────────────────────────────────────────────
  Schritt "A schreibt: $Text"
  Nimm-Geraet $A
  $kurz = ($adr[$B].Substring(0, 4)).ToUpper()
  $k = Warte-AufText $kurz 60
  if (-not $k) { throw 'A: die Unterhaltung ist nicht in der Liste' }
  Tippe $k
  Start-Sleep -Seconds 2

  Sende 'A' $Text
  Gut 'abgeschickt'

  # ── B liest ────────────────────────────────────────────────────────────
  Schritt 'B nachsehen'
  Nimm-Geraet $B
  $kurzA = ($adr[$A].Substring(0, 4)).ToUpper()
  if (-not (Warte-AufNachricht $Text $kurzA)) { throw "B: '$Text' ist nicht angekommen" }
  Gut "B hat '$Text' bekommen"

  # ── B antwortet ────────────────────────────────────────────────────────
  # DIE GEGENRICHTUNG ist der Teil, den die erste Nachricht nicht beweist:
  # B schreibt auf der Sitzung, die A per PQXDH aufgebaut hat, und A muss die
  # erste Nachricht von B entschluesseln.
  Schritt "B antwortet: $Antwort"
  if (-not (Finde-Knoten (Lies-Oberflaeche) '^SEND$')) {
    $k = Finde-Knoten (Lies-Oberflaeche) $kurzA
    if (-not $k) { throw 'B: die Unterhaltung mit A ist nicht in der Liste' }
    Tippe $k
    Start-Sleep -Seconds 2
  }
  Sende 'B' $Antwort
  Gut 'abgeschickt'

  Schritt 'A nachsehen'
  Nimm-Geraet $A
  if (-not (Warte-AufNachricht $Antwort $kurz)) { throw "A: '$Antwort' ist nicht angekommen" }
  Gut "A hat '$Antwort' bekommen"

  Write-Host "`nDauer: $([int]((Get-Date) - $script:start).TotalSeconds) s" -ForegroundColor Cyan
  Gut 'DURCHSTICH GESCHAFFT'
  if ($Lokal) {
    Write-Host "`nRelay lokal, nichts auf relay.bitdm.net. Adressen:" -ForegroundColor Yellow
  } else {
    Write-Host "`nAuf relay.bitdm.net stehen jetzt zwei Karteileichen:" -ForegroundColor Yellow
  }
  Write-Host "  $($adr[$A])"
  Write-Host "  $($adr[$B])"
  exit 0
} catch {
  Schlecht $_.Exception.Message
  exit 1
} finally {
  if (-not $LassStehen -and -not $Weiter) {
    foreach ($z in $A, $B) { Nimm-Geraet $z; AdbStill emu kill | Out-Null }
  }
}
