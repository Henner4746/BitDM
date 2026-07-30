# durchstich_zwei_geraete.ps1 — eine Nachricht von einem Telefon zum anderen.
#
# WAS DIESER LAUF BEWEIST, das kein Einheitentest beweisen kann: dass zwei
# echte Installationen auf echtem Android ueber einen echten Server eine
# Sitzung aufbauen und eine Nachricht austauschen. Kontaktanfrage, Bestaetigen,
# X3DH, Double Ratchet, WebSocket, TLS — alles am Stueck, nichts nachgebaut.
#
# ZWEI EMULATOREN BRAUCHEN RUND 11 GB. Vorher pruefen, sonst faellt der
# zweite mitten im Hochfahren um, und die Meldung deutet auf alles Moegliche
# ausser auf Speichermangel.
#
# WELCHER SERVER: der echte relay.bitdm.net. Ein Server auf diesem Rechner
# waere schoener, geht aber nicht ohne die Einstellung "eigener Server" —
# siehe docs/EIGENER-SERVER.md. Jeder Lauf hinterlaesst deshalb ZWEI
# Karteileichen dort. Ihre Adressen stehen am Ende im Bericht.

[CmdletBinding()]
param(
  [string]$AvdA = 'BitDM_B',
  [string]$AvdB = 'BitDM_C',
  [int]$PortA = 5554,
  [int]$PortB = 5556,
  [string]$Apk = "$PSScriptRoot\..\app\build\app\outputs\flutter-apk\app-release.apk",
  [string]$Text = 'Durchstich',
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

$A = "emulator-$PortA"
$B = "emulator-$PortB"

try {
  if (-not $Weiter) {
    Schritt 'zwei Emulatoren starten'
    $frei = (Get-CimInstance Win32_PerfRawData_PerfOS_Memory).AvailableMBytes / 1024
    if ($frei -lt 12) {
      throw ("nur {0:N1} GB verfuegbar — zwei Emulatoren brauchen rund 11 GB" -f $frei)
    }
    Starte-Emulator $AvdA $PortA
    Starte-Emulator $AvdB $PortB
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
  $kopf = Finde-Rahmen (Lies-Oberflaeche) 'CHATS.*\+'
  if (-not $kopf) { throw 'A: die Ueberschrift mit dem Plus fehlt' }
  Adb shell input tap ($kopf.Rechts - (Dp 26)) ($kopf.Oben + (Dp 18)) | Out-Null
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

  # Das Schreibfeld steht links neben SEND und hat, solange es leer ist,
  # keinen eigenen Knoten. Also SEND suchen und daneben tippen.
  $send = Finde-Knoten (Lies-Oberflaeche) '^SEND$'
  if (-not $send) { throw 'A: kein Knopf SEND' }
  Adb shell input tap ($send.X - 500) $send.Y | Out-Null
  Start-Sleep -Milliseconds 700
  Adb shell input text $Text | Out-Null
  Start-Sleep -Milliseconds 700

  # SEND NEU SUCHEN. Mit offener Tastatur schrumpft der sichtbare Bereich, und
  # der Knopf sitzt tausend Pixel weiter oben. Der erste Versuch tippte auf
  # die alte Stelle, traf die Leiste darunter, und der Text blieb im Feld
  # stehen — ohne dass irgendetwas nach einem Fehler aussah.
  $send = Finde-Knoten (Lies-Oberflaeche) '^SEND$'
  if (-not $send) { throw 'A: SEND ist nach der Eingabe verschwunden' }
  Tippe $send
  Start-Sleep -Seconds 3
  if ((Lies-Oberflaeche) -notmatch [regex]::Escape($Text)) {
    throw 'A: die Nachricht steht nicht im eigenen Verlauf'
  }
  Gut 'abgeschickt'

  # ── B liest ────────────────────────────────────────────────────────────
  Schritt 'B nachsehen'
  Nimm-Geraet $B
  $angekommen = $false
  $ende = (Get-Date).AddSeconds(90)
  while ((Get-Date) -lt $ende -and -not $angekommen) {
    if ((Lies-Oberflaeche 3) -match [regex]::Escape($Text)) { $angekommen = $true; break }
    Start-Sleep -Seconds 2
  }
  if (-not $angekommen) {
    # Vielleicht liegt sie in der Unterhaltung und nicht in der Liste.
    $kurzA = ($adr[$A].Substring(0, 4)).ToUpper()
    $k = Finde-Knoten (Lies-Oberflaeche) $kurzA
    if ($k) {
      Tippe $k
      Start-Sleep -Seconds 2
      if ((Lies-Oberflaeche) -match [regex]::Escape($Text)) { $angekommen = $true }
    }
  }
  if (-not $angekommen) { throw "B: '$Text' ist nicht angekommen" }
  Gut "B hat '$Text' bekommen"

  Write-Host "`nDauer: $([int]((Get-Date) - $script:start).TotalSeconds) s" -ForegroundColor Cyan
  Gut 'DURCHSTICH GESCHAFFT'
  Write-Host "`nAuf relay.bitdm.net stehen jetzt zwei Karteileichen:" -ForegroundColor Yellow
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
