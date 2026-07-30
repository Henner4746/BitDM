# emulator_lauf.ps1 — die App im Emulator bedienen, ohne dass jemand zusieht.
#
# WOFUER
# Die Einheitentests pruefen den Kern. Was sie NICHT pruefen koennen: ob die
# App auf einem echten Android startet, ob die Oberflaeche zusammenhaengt, ob
# eine Nachricht von aussen wirklich im Verlauf ankommt. Genau das tut dieses
# Skript — und zwar ohne ein Telefon, das jemandem gehoert.
#
# WARUM POWERSHELL UND NICHT BASH
# Git-Bash uebersetzt Pfade, die wie Unix-Pfade aussehen. `uiautomator dump
# /sdcard/x.xml` landet dann in C:\Program Files\Git\sdcard\x.xml — auf dem
# HOST, nicht auf dem Geraet. MSYS_NO_PATHCONV=1 behebt das und zerlegt dafuer
# `adb push`, weil dessen erster Pfad ein echter Windows-Pfad ist. Also gar
# nicht erst mit Bash anfangen.
#
# WAS ES NICHT TUT
# Bildvergleiche. Die App setzt FLAG_SECURE, `screencap` liefert eine leere
# Flaeche. Geprueft wird ausschliesslich ueber die Beschriftungen im
# uiautomator-Abzug und ueber Dateien im App-Ordner.

[CmdletBinding()]
param(
  [string]$Avd = 'BitDM_B',
  [int]$Port = 5554,
  [string]$Apk = "$PSScriptRoot\..\app\build\app\outputs\flutter-apk\app-release.apk",
  [string]$Relay = 'http://10.0.2.2:8080',
  # Den Relay auf den eigenen Rechner umbiegen. BRAUCHT DIE EINSTELLUNG
  # "eigener Server" in der App — die ist am 26.07.2026 wieder entfernt
  # worden, siehe docs/EIGENER-SERVER.md. Ohne sie laeuft alles bis
  # einschliesslich der eigenen Adresse, und der Teil danach entfaellt.
  #
  # WARUM ES OHNE DIE EINSTELLUNG NICHT GEHT: den Namen relay.bitdm.net auf
  # 10.0.2.2 umzubiegen waere leicht (eigener DNS-Server, -dns-server). Aber
  # die App spricht https, und fuer diesen Namen gibt es auf dem eigenen
  # Rechner kein gueltiges Zertifikat. Ein eigenes in den Systemspeicher zu
  # legen verlangt Root, und das Abbild mit dem Play Store gibt es nicht her.
  [switch]$MitEigenemServer,
  # Bei einem Fehlschlag stehen lassen, damit man nachsehen kann.
  [switch]$LassStehen,
  # Ueberspringt Start und Installation — fuer den zweiten Versuch, wenn der
  # Emulator schon laeuft. Spart eine Minute je Durchlauf.
  [switch]$Weiter
)

$ErrorActionPreference = 'Stop'
$sdk = "$env:LOCALAPPDATA\Android\Sdk"
$adb = "$sdk\platform-tools\adb.exe"
$emu = "$sdk\emulator\emulator.exe"
$ziel = "emulator-$Port"
$paket = 'com.bitdm.bitdm'

function Sag($t) { Write-Host "  $t" -ForegroundColor DarkGray }
function Schritt($t) { Write-Host "`n[$([int]((Get-Date) - $script:start).TotalSeconds)s] $t" -ForegroundColor Cyan }
function Gut($t) { Write-Host "  OK  $t" -ForegroundColor Green }
function Schlecht($t) { Write-Host "  FEHLER  $t" -ForegroundColor Red }

$script:start = Get-Date

# KEIN `2>$null` BEI NATIVEN PROGRAMMEN. Windows PowerShell verpackt jede
# stderr-Zeile in einen ErrorRecord; mit $ErrorActionPreference='Stop' wird
# daraus eine Ausnahme. "* daemon not running; starting now at tcp:5037" ist
# aber die normalste Meldung der Welt — und das Skript brach daran ab, mit
# genau diesem Satz als angeblichem Fehler.
function Adb {
  $alt = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $adb -s $ziel @args } finally { $ErrorActionPreference = $alt }
}

# DASSELBE, ABER ALS EIN STRING.
#
# WARUM DAS EINE EIGENE FUNKTION IST: adb liefert ein ARRAY von Zeilen. Und
# `$array -notmatch 'Success'` filtert das Array, statt einen Wahrheitswert
# zu liefern — heraus kommen alle Zeilen OHNE "Success", und die Liste ist
# fast nie leer. Eine gegluekte Installation ("Performing Streamed Install /
# Success") wurde damit als Fehlschlag gemeldet. Der Vergleich muss auf einem
# String stattfinden, nicht auf einer Liste.
function AdbText { (Adb @args) -join "`n" }

# DASSELBE, ABER OHNE GEMECKER.
#
# Waehrend der Emulator hochfaehrt, antwortet adb rund fuenfzehnmal mit
# "device offline" — voellig normal, aber PowerShell sammelt jede dieser
# Zeilen als Fehlerobjekt und schuettet sie am Ende des Skripts aus. Der
# Bericht eines gegluecktenden Laufs bestand zu neun Zehnteln aus roten
# Bloecken. `2>&1` durch eine Pipeline zieht die Zeilen als Text ein, bevor
# sie im Fehlerstrom landen.
function AdbStill {
  $alt = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { (& $adb -s $ziel @args 2>&1 | ForEach-Object { "$_" }) -join "`n" }
  finally { $ErrorActionPreference = $alt }
}

# ── Bereitschaft ───────────────────────────────────────────────────────────
# DREI PRUEFUNGEN, nicht eine. `adb wait-for-device` kehrt zurueck, sobald die
# Verbindung steht — da laeuft noch nicht einmal init durch. `boot_completed`
# allein reicht auch nicht: die Bootanimation laeuft dann noch, und ein
# `pm install` in diesem Moment scheitert mit einer Meldung, die nach einem
# Fehler in der APK aussieht.
function Warte-AufBereitschaft([int]$Sekunden = 300) {
  $ende = (Get-Date).AddSeconds($Sekunden)
  while ((Get-Date) -lt $ende) {
    $b = (AdbStill shell getprop sys.boot_completed) -replace '\s', ''
    $a = (AdbStill shell getprop init.svc.bootanim) -replace '\s', ''
    if ($b -eq '1' -and $a -ne 'running') {
      if ((AdbStill shell pm path android) -match 'package:') { return $true }
    }
    Start-Sleep -Seconds 2
  }
  return $false
}

# ── Oberflaeche lesen ──────────────────────────────────────────────────────
# DAS STARTRENNEN: `uiautomator dump` meldet sich selbst als
# Barrierefreiheits-Client an. Flutter schaltet seinen Semantikbaum erst
# daraufhin ein. Der erste Abzug hat deshalb 0 Knoten, der zweite einen, ab
# dem dritten stimmt es. Das ist KEIN Zeichen dafuer, dass die Semantik fehlt
# — die urspruengliche Annahme war falsch und hat Stunden gekostet.
function Lies-Oberflaeche([int]$Versuche = 6) {
  for ($i = 1; $i -le $Versuche; $i++) {
    Adb shell uiautomator dump /sdcard/ui.xml | Out-Null
    $xml = AdbText shell cat /sdcard/ui.xml
    if ($xml -and $xml.Length -gt 400) {
      $knoten = [regex]::Matches($xml, '<node[^>]*>')
      if ($knoten.Count -ge 3) { return $xml }
    }
    Start-Sleep -Milliseconds 700
  }
  return $xml
}

# Beschriftungen stehen bei Flutter in content-desc. text= ist LEER — bei
# jedem einzelnen Knoten. Wer nur text= durchsucht, findet nie etwas und haelt
# die Oberflaeche fuer unlesbar.
# NUR-KLICKBAR ZUERST. Die Suche nach 'create' fand zunaechst den Fliesstext
# "BitDM creates an identity on this device..." — er steht im Baum vor dem
# Knopf. Ein Tipp mitten in einen Absatz tut nichts, und der Lauf scheiterte
# drei Schritte spaeter an einer Stelle, die mit der Ursache nichts zu tun
# hatte.
function Finde-Knoten($xml, [string]$Muster, [switch]$Alle) {
  if (-not $Alle) {
    $k = Finde-InKnoten $xml $Muster $true
    if ($k) { return $k }
  }
  return Finde-InKnoten $xml $Muster $false
}

function Finde-InKnoten($xml, [string]$Muster, [bool]$NurKlickbar) {
  foreach ($m in [regex]::Matches($xml, '<node[^>]*/?>')) {
    $k = $m.Value
    if ($NurKlickbar -and $k -notmatch 'clickable="true"') { continue }
    $d = [regex]::Match($k, 'content-desc="([^"]*)"').Groups[1].Value
    $t = [regex]::Match($k, '\stext="([^"]*)"').Groups[1].Value
    if (($d -and $d -match $Muster) -or ($t -and $t -match $Muster)) {
      $b = [regex]::Match($k, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
      if ($b.Success) {
        return [pscustomobject]@{
          Text = if ($d) { $d } else { $t }
          X    = [int](([int]$b.Groups[1].Value + [int]$b.Groups[3].Value) / 2)
          Y    = [int](([int]$b.Groups[2].Value + [int]$b.Groups[4].Value) / 2)
        }
      }
    }
  }
  return $null
}

function Alle-Beschriftungen($xml) {
  $l = @()
  foreach ($m in [regex]::Matches($xml, 'content-desc="([^"]+)"')) { $l += $m.Groups[1].Value }
  return $l
}

function Tippe($knoten) {
  Adb shell input tap $knoten.X $knoten.Y | Out-Null
  Start-Sleep -Milliseconds 900
}

# Wartet, bis eine Beschriftung auftaucht — statt fest zu schlafen. Ein festes
# Start-Sleep ist auf einem ausgelasteten Rechner zu kurz und sonst zu lang.
function Warte-AufText([string]$Muster, [int]$Sekunden = 25) {
  $ende = (Get-Date).AddSeconds($Sekunden)
  while ((Get-Date) -lt $ende) {
    $xml = Lies-Oberflaeche 3
    $k = Finde-Knoten $xml $Muster
    if ($k) { return $k }
    Start-Sleep -Milliseconds 600
  }
  return $null
}

$fehler = @()

try {
  # ── Emulator ─────────────────────────────────────────────────────────────
  if (-not $Weiter) {
    Schritt "Emulator $Avd starten"
    # NICHT FreePhysicalMemory: das zaehlt den Bereitschaftsspeicher nicht mit,
    # den Windows jederzeit hergibt, und meldet 5 GB, wo 12 verfuegbar sind.
    #
    # UND NICHT Get-Counter: die Zaehlernamen sind UEBERSETZT. Auf diesem
    # Rechner heisst der Pfad "\Arbeitsspeicher\Verfuegbare MB", und
    # '\Memory\Available MBytes' scheitert mit "Das angegebene Objekt wurde
    # nicht auf dem Computer gefunden" — einer Meldung, die nach einem
    # fehlenden Geraet klingt und nichts damit zu tun hat.
    $frei = (Get-CimInstance Win32_PerfRawData_PerfOS_Memory).AvailableMBytes / 1024
    # 4,5 GB ist gemessen und nicht geschaetzt: bei 5,1 GB verfuegbar ist der
    # Emulator am 26.07.2026 sauber hochgekommen. Die ~5,5 GB, die er sich am
    # Ende nimmt, holt er sich zum Teil aus dem Bereitschaftsspeicher.
    if ($frei -lt 4.5) {
      throw ("nur {0:N1} GB verfuegbar — ein Emulator braucht rund 5,5 GB (trotz -memory 2048). Erst Gradle beenden: gradlew --stop" -f $frei)
    }
    Start-Process -FilePath $emu -ArgumentList @(
      '-avd', $Avd, '-port', "$Port", '-no-window', '-no-audio',
      '-no-boot-anim', '-no-snapshot', '-gpu', 'swiftshader_indirect',
      '-memory', '2048',
      # KEINE NAMENSAUFLOESUNG. Ohne das meldet sich jede Testidentitaet beim
      # ERSTEN Start am ECHTEN relay.bitdm.net an — der Weg durch das
      # Onboarding verbindet, bevor man die Adresse ueberhaupt umstellen kann.
      # Drei Nachtlaeufe waeren drei Karteileichen im Server fremder Leute.
      # 10.0.2.2 ist eine Zahl und braucht keinen Namen, der Testaufbau
      # funktioniert also weiter.
      '-dns-server', '127.0.0.1'
    ) -WindowStyle Hidden
    Sag 'gestartet, warte auf Bereitschaft (Kaltstart ~65 s)'
    if (-not (Warte-AufBereitschaft 300)) { throw 'Emulator wurde nicht bereit' }
    Gut 'Emulator bereit'

    Schritt 'App installieren'
    if (-not (Test-Path $Apk)) { throw "keine APK unter $Apk" }
    Adb uninstall $paket | Out-Null
    $r = AdbText install -r $Apk
    if ($r -notmatch 'Success') { throw "Installation fehlgeschlagen: $r" }
    Gut ('installiert, {0:N1} MB' -f ((Get-Item $Apk).Length / 1MB))
  }

  # ── Start ────────────────────────────────────────────────────────────────
  Schritt 'App starten'
  Adb shell am force-stop $paket | Out-Null
  # `monkey` schreibt seine Argumentliste nach stderr — bei jedem Aufruf ein
  # halber Bildschirm angeblicher Fehler. `am start` ist ausserdem genauer.
  Adb shell am start -n "$paket/.MainActivity" | Out-Null
  Start-Sleep -Seconds 4

  $xml = Lies-Oberflaeche
  $bes = Alle-Beschriftungen $xml
  if ($bes.Count -eq 0) { throw 'die Oberflaeche gibt nichts her — App vermutlich abgestuerzt' }
  Gut "$($bes.Count) Beschriftungen gelesen"
  Sag (($bes | Select-Object -First 6) -join ' | ')

  # ── Identitaet ───────────────────────────────────────────────────────────
  Schritt 'Identitaet anlegen'
  $k = Finde-Knoten $xml '^CREATE IDENTITY$'
  if (-not $k) {
    Sag 'kein Knopf "CREATE IDENTITY" — vermutlich gibt es die Identitaet schon'
  } else {
    Tippe $k
    $k = Warte-AufText '^I WROTE THEM DOWN$' 20
    if (-not $k) { throw 'die 12 Woerter wurden nicht angezeigt' }
    Gut 'Wiederherstellungsphrase angezeigt'
    Tippe $k

    # SKIP FOR NOW: der Testlauf hat keinen Fingerabdruck und keine
    # Bildschirmsperre. Wer hier CONTINUE tippt, bekommt eine Sperre, die er
    # nie wieder aufbekommt.
    $k = Warte-AufText '^SKIP FOR NOW$' 20
    if (-not $k) { throw 'der Bildschirm mit den Faktoren kam nicht' }
    Tippe $k
    Start-Sleep -Seconds 2
  }

  # ── Die eigene Adresse ───────────────────────────────────────────────────
  Schritt 'eigene Adresse ablesen'
  $k = Warte-AufText '^MY ID$' 20
  if (-not $k) { throw 'der Bildschirm "MY ID" kam nicht' }
  $xml = Lies-Oberflaeche
  # Die Adresse steht in Vierergruppen, jede Gruppe ein eigener Knoten. Der
  # Reihenfolge im Baum ist zu trauen — sie ist die Lesereihenfolge.
  #
  # NUR NICHT-KLICKBARE KNOTEN. Der Knopf "COPY" ist ebenfalls vier
  # Grossbuchstaben aus demselben Vorrat und haengte sich beim ersten Lauf
  # hinten an die Adresse. Die Abfrage beim Relay lief danach gegen eine
  # Adresse, die es nicht gibt — und meldete "nicht angemeldet", obwohl die
  # Anmeldung laengst durch war. Eine Pruefung, die aus dem falschen Grund rot
  # wird, ist schlimmer als keine.
  $gruppen = @()
  foreach ($m in [regex]::Matches($xml, '<node[^>]*/?>')) {
    if ($m.Value -match 'clickable="true"') { continue }
    $d = [regex]::Match($m.Value, 'content-desc="([A-Z2-7]{4})"')
    if ($d.Success) { $gruppen += $d.Groups[1].Value }
  }
  $adresse = ($gruppen -join '').ToLower()
  if ($adresse.Length -ne 56) {
    throw "Adresse hat $($adresse.Length) statt 56 Zeichen: $adresse"
  }
  Gut "Adresse: $adresse"

  if (-not $MitEigenemServer) {
    Write-Host "`nDauer: $([int]((Get-Date) - $script:start).TotalSeconds) s"
    Sag 'Der Teil mit dem eigenen Server entfaellt: die Einstellung dafuer'
    Sag 'ist nicht in der App. Mit -MitEigenemServer und der Einstellung aus'
    Sag 'docs/EIGENER-SERVER.md laeuft er wieder.'
    if ($fehler.Count -gt 0) { foreach ($f in $fehler) { Schlecht $f }; exit 1 }
    Gut 'Durchlauf ohne Beanstandung (ohne Serverteil)'
    exit 0
  }

  # ── Eigenen Server eintragen ─────────────────────────────────────────────
  Schritt "Relay auf $Relay umstellen"
  $k = Finde-Knoten (Lies-Oberflaeche) '^SETTINGS$'
  if (-not $k) { throw 'kein Reiter SETTINGS' }
  Tippe $k

  # Bis der Abschnitt sichtbar ist. Die Zahl der Wische ist nicht fest: die
  # Liste ist je nach eingeschalteten Faktoren verschieden lang.
  $marke = $null
  for ($i = 0; $i -lt 8 -and -not $marke; $i++) {
    Adb shell input swipe 640 2000 640 500 400 | Out-Null
    Start-Sleep -Milliseconds 800
    $marke = Finde-Knoten (Lies-Oberflaeche) '^RELAY ADDRESS$' -Alle
  }
  if (-not $marke) { throw 'der Abschnitt "OWN SERVER" wurde nicht gefunden' }

  # DAS TEXTFELD SELBST HAT KEINE BESCHRIFTUNG — es taucht im Abzug erst auf,
  # wenn etwas darin steht (dann in text=, nicht in content-desc). Getroffen
  # wird es ueber die Beschriftung darueber: rund 60 Pixel tiefer.
  Adb shell input tap $marke.X ($marke.Y + 62) | Out-Null
  Start-Sleep -Milliseconds 800
  Adb shell input text $Relay | Out-Null
  Start-Sleep -Milliseconds 500
  # ZURUECK schliesst die Tastatur. Ohne das steht der Knopf ausserhalb des
  # sichtbaren Bereichs, und der Tipp landet auf der unteren Leiste.
  Adb shell input keyevent 4 | Out-Null
  Start-Sleep -Milliseconds 800

  $xml = Lies-Oberflaeche
  if ($xml -notmatch [regex]::Escape($Relay)) { throw 'die Adresse steht nicht im Feld' }
  $k = Finde-Knoten $xml '^APPLY$'
  if (-not $k) { throw 'kein Knopf APPLY' }
  Tippe $k
  Start-Sleep -Seconds 3

  $xml = Lies-Oberflaeche
  if ($xml -match "Currently talking to: $([regex]::Escape($Relay))") {
    Gut 'die App nennt den eigenen Server'
  } else {
    $fehler += 'die App zeigt weiter den mitgelieferten Server an'
  }

  # ── Der harte Nachweis: der Relay hat sie gesehen ────────────────────────
  #
  # ALLES BISHERIGE WAR NUR OBERFLAECHE. Eine App kann jeden Text anzeigen.
  # Erst wenn der Server auf DIESEM Rechner die Adresse kennt, ist wirklich
  # etwas geflossen — und zwar genau die Adresse, die die App anzeigt.
  #
  # `run-as` faellt dafuer aus: bei einer Release-APK antwortet es "package
  # not debuggable". Der Umweg ueber den Server ist ohnehin der bessere
  # Nachweis, weil er beide Enden zugleich prueft.
  Schritt 'beim Relay nachsehen'
  $gefunden = $false
  for ($i = 0; $i -lt 20 -and -not $gefunden; $i++) {
    try {
      $h = (Invoke-WebRequest -UseBasicParsing "$($Relay -replace '10\.0\.2\.2', '127.0.0.1')/prekey/$adresse" -TimeoutSec 5)
      if ($h.StatusCode -eq 200) { $gefunden = $true }
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  if ($gefunden) {
    Gut 'der Relay kennt die Adresse — die App hat sich dort angemeldet'
  } else {
    $fehler += 'der Relay kennt die Adresse nicht: die Anmeldung ist nicht angekommen'
  }

  Write-Host "`nDauer: $([int]((Get-Date) - $script:start).TotalSeconds) s"
  if ($fehler.Count -gt 0) {
    foreach ($f in $fehler) { Schlecht $f }
    exit 1
  }
  Gut 'Durchlauf ohne Beanstandung'
  exit 0
} catch {
  Schlecht $_.Exception.Message
  exit 2
} finally {
  if (-not $LassStehen -and -not $Weiter) {
    # Sanft: `emu kill` laesst den Emulator seine Daten schreiben. Ein
    # Stop-Process laesst eine beschaedigte AVD zurueck, die beim naechsten
    # Start nicht mehr hochkommt.
    AdbStill emu kill | Out-Null
  }
}
