# geraet.ps1 — ein Emulator, bedienbar. Wird von den Testlaeufen eingebunden.
#
# Getrennt von emulator_lauf.ps1, weil der Durchstich ZWEI Geraete braucht und
# jede Funktion darin sonst ein Ziel als Parameter durchschleifen muesste.
# Hier ist das Ziel in $script:Ziel gemerkt und wird mit Nimm-Geraet gewechselt.

$script:Sdk = "$env:LOCALAPPDATA\Android\Sdk"
$script:AdbExe = "$script:Sdk\platform-tools\adb.exe"
$script:Emu = "$script:Sdk\emulator\emulator.exe"
$script:Ziel = 'emulator-5554'
$script:Paket = 'com.bitdm.bitdm'

function Nimm-Geraet([string]$Ziel) { $script:Ziel = $Ziel }

# KEIN `2>$null` bei nativen Programmen: Windows PowerShell verpackt jede
# stderr-Zeile in einen ErrorRecord, der unter ErrorActionPreference='Stop'
# zur Ausnahme wird. "device offline" waehrend des Hochfahrens ist normal.
function Adb {
  $alt = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $script:AdbExe -s $script:Ziel @args } finally { $ErrorActionPreference = $alt }
}

# Als EIN String. `$array -notmatch 'Success'` filtert das Array, statt einen
# Wahrheitswert zu liefern — eine gegluecke Installation galt damit als
# Fehlschlag.
function AdbText { (Adb @args) -join "`n" }

function AdbStill {
  $alt = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { (& $script:AdbExe -s $script:Ziel @args 2>&1 | ForEach-Object { "$_" }) -join "`n" }
  finally { $ErrorActionPreference = $alt }
}

function Starte-Emulator([string]$Avd, [int]$Port, [switch]$OhneDns) {
  $args = @('-avd', $Avd, '-port', "$Port", '-no-window', '-no-audio',
            '-no-boot-anim', '-no-snapshot', '-gpu', 'swiftshader_indirect',
            '-memory', '2048')
  # Ohne Namensaufloesung erreicht die App den echten Relay nicht. Nur
  # sinnvoll, wenn ein Server auf 10.0.2.2 antwortet.
  if ($OhneDns) { $args += @('-dns-server', '127.0.0.1') }
  Start-Process -FilePath $script:Emu -ArgumentList $args -WindowStyle Hidden
}

# DREI PRUEFUNGEN. `adb wait-for-device` kehrt zurueck, bevor init durch ist;
# boot_completed allein laesst die Bootanimation noch laufen, und ein
# `pm install` scheitert dann mit einer Meldung, die nach einem Fehler in der
# APK aussieht.
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

# DAS STARTRENNEN: `uiautomator dump` meldet sich selbst als
# Barrierefreiheits-Client an; Flutter schaltet seinen Semantikbaum erst
# daraufhin ein. Abzug 1 hat 0 Knoten, Abzug 2 einen, ab 3 stimmt es.
function Lies-Oberflaeche([int]$Versuche = 6) {
  for ($i = 1; $i -le $Versuche; $i++) {
    Adb shell uiautomator dump /sdcard/ui.xml | Out-Null
    $xml = AdbText shell cat /sdcard/ui.xml
    if ($xml -match 'permissioncontroller') { Raeume-Dialoge-Weg; continue }
    if ($xml -and $xml.Length -gt 400 -and
        [regex]::Matches($xml, '<node[^>]*>').Count -ge 3) { return $xml }
    Start-Sleep -Milliseconds 700
  }
  return $xml
}

# Beschriftungen stehen bei Flutter in content-desc; text= ist bei allem
# ausser Eingabefeldern leer. Klickbare Knoten zuerst, sonst findet die Suche
# nach 'create' den Fliesstext "BitDM creates an identity...".
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

# Bildschirmbreite, -hoehe und Punktdichte des Geraets.
#
# WOFUER: feste Bildpunkt-Koordinaten sind nur auf genau einem Geraet richtig.
# Der Tipp auf das Plus lag bei 1200 — auf einem 1080 breiten Bildschirm also
# ausserhalb. Der Lauf meldete daraufhin "der Bildschirm ADD CONTACT kam
# nicht", was auf alles Moegliche deutet, nur nicht auf die Ursache.
function Geometrie {
  $g = AdbStill shell wm size
  $d = AdbStill shell wm density
  $m = [regex]::Match($g, 'Override size:\s*(\d+)x(\d+)')
  if (-not $m.Success) { $m = [regex]::Match($g, 'Physical size:\s*(\d+)x(\d+)') }
  $dm = [regex]::Match($d, 'Override density:\s*(\d+)')
  if (-not $dm.Success) { $dm = [regex]::Match($d, 'Physical density:\s*(\d+)') }
  return [pscustomobject]@{
    Breite = [int]$m.Groups[1].Value
    Hoehe  = [int]$m.Groups[2].Value
    Dichte = [int]$dm.Groups[1].Value
  }
}

# Ein Mass in dp in Bildpunkte dieses Geraets.
function Dp([int]$dp) { [int]($dp * (Geometrie).Dichte / 160) }

function Tippe($knoten) {
  Adb shell input tap $knoten.X $knoten.Y | Out-Null
  Start-Sleep -Milliseconds 900
}

# Wartet, bis eine Beschriftung auftaucht. Ein festes Start-Sleep ist auf
# einem Rechner mit zwei Emulatoren zu kurz und sonst zu lang.
function Warte-AufText([string]$Muster, [int]$Sekunden = 30) {
  $ende = (Get-Date).AddSeconds($Sekunden)
  while ((Get-Date) -lt $ende) {
    $k = Finde-Knoten (Lies-Oberflaeche 3) $Muster
    if ($k) { return $k }
    Start-Sleep -Milliseconds 600
  }
  return $null
}

# Wie Finde-Knoten, gibt aber den ganzen Rahmen zurueck statt nur die Mitte.
# Gebraucht, wo an einer KANTE getippt wird und nicht in der Mitte — etwa beim
# Plus, das in derselben Semantik-Einheit steckt wie die ganze Ueberschrift.
function Finde-Rahmen($xml, [string]$Muster) {
  foreach ($m in [regex]::Matches($xml, '<node[^>]*/?>')) {
    $d = [regex]::Match($m.Value, 'content-desc="([^"]*)"').Groups[1].Value
    if (-not ($d -and $d -match $Muster)) { continue }
    $b = [regex]::Match($m.Value, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
    if (-not $b.Success) { continue }
    return [pscustomobject]@{
      Links = [int]$b.Groups[1].Value; Oben   = [int]$b.Groups[2].Value
      Rechts= [int]$b.Groups[3].Value; Unten  = [int]$b.Groups[4].Value
    }
  }
  return $null
}

function Alle-Beschriftungen($xml) {
  $l = @()
  foreach ($m in [regex]::Matches($xml, 'content-desc="([^"]+)"')) { $l += $m.Groups[1].Value }
  return $l
}

function Setze-App-Neu([string]$Apk) {
  AdbStill uninstall $script:Paket | Out-Null
  $r = AdbText install -r $Apk
  if ($r -notmatch 'Success') { throw "Installation fehlgeschlagen: $r" }

  # DIE BENACHRICHTIGUNGSFREIGABE VORWEG ERTEILEN.
  #
  # Sonst fragt Android beim ersten Ereignis danach — und zwar mit einem
  # SYSTEMDIALOG, der die Flutter-Oberflaeche vollstaendig verdeckt. Der Abzug
  # zeigt dann 13 Knoten von com.google.android.permissioncontroller und kein
  # einziges content-desc, was aussieht, als waere die App abgestuerzt. Genau
  # das ist am 26.07.2026 beim zweiten Geraet passiert, in dem Moment, in dem
  # die Kontaktanfrage ankam.
  AdbStill shell pm grant $script:Paket android.permission.POST_NOTIFICATIONS | Out-Null
}

# Wegtippen, was sich vor die App geschoben hat.
#
# Die Freigabe oben verhindert den haeufigsten Fall, aber nicht jeden: Android
# schiebt auch von sich aus Dialoge davor. Systemdialoge tragen ihre
# Beschriftung in text=, nicht in content-desc — die gewohnte Suche findet sie
# also nicht.
function Raeume-Dialoge-Weg {
  for ($i = 0; $i -lt 3; $i++) {
    $xml = AdbText shell cat /sdcard/ui.xml
    if ($xml -notmatch 'permissioncontroller|android:id/button1') { return }
    $k = $null
    foreach ($m in [regex]::Matches($xml, '<node[^>]*/?>')) {
      if ($m.Value -notmatch 'clickable="true"') { continue }
      $t = [regex]::Match($m.Value, '\stext="([^"]*)"').Groups[1].Value
      if ($t -match '^(Allow|Zulassen|OK|While using the app)$') {
        $b = [regex]::Match($m.Value, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
        $k = [pscustomobject]@{
          X = [int](([int]$b.Groups[1].Value + [int]$b.Groups[3].Value) / 2)
          Y = [int](([int]$b.Groups[2].Value + [int]$b.Groups[4].Value) / 2) }
        break
      }
    }
    if (-not $k) { return }
    Adb shell input tap $k.X $k.Y | Out-Null
    Start-Sleep -Milliseconds 900
    Adb shell uiautomator dump /sdcard/ui.xml | Out-Null
  }
}

function Starte-App {
  Adb shell am force-stop $script:Paket | Out-Null
  Adb shell am start -n "$script:Paket/.MainActivity" | Out-Null
  Start-Sleep -Seconds 4
}

# Durch das Onboarding und die Adresse zurueckgeben.
function Lege-Identitaet-An {
  $k = Finde-Knoten (Lies-Oberflaeche) '^CREATE IDENTITY$'
  if ($k) {
    Tippe $k
    $k = Warte-AufText '^I WROTE THEM DOWN$' 30
    if (-not $k) { throw 'die 12 Woerter wurden nicht angezeigt' }
    Tippe $k
    # SKIP FOR NOW und nicht CONTINUE: der Testlauf hat weder Fingerabdruck
    # noch Bildschirmsperre und kaeme hinter eine Sperre, die er nie wieder
    # aufbekommt.
    $k = Warte-AufText '^SKIP FOR NOW$' 30
    if (-not $k) { throw 'der Bildschirm mit den Faktoren kam nicht' }
    Tippe $k
    Start-Sleep -Seconds 2
  }
  return Lies-Adresse
}

# Die Adresse steht auf dem Reiter MY ID in Vierergruppen, jede ein eigener
# Knoten. NUR NICHT-KLICKBARE: der Knopf "COPY" ist ebenfalls vier
# Grossbuchstaben aus demselben Vorrat und haengte sich beim ersten Lauf
# hinten an die Adresse.
function Lies-Adresse {
  $k = Warte-AufText '^MY ID$' 30
  if (-not $k) { throw 'der Reiter MY ID kam nicht' }
  Tippe $k
  $xml = Lies-Oberflaeche
  $gruppen = @()
  foreach ($m in [regex]::Matches($xml, '<node[^>]*/?>')) {
    if ($m.Value -match 'clickable="true"') { continue }
    $d = [regex]::Match($m.Value, 'content-desc="([A-Z2-7]{4})"')
    if ($d.Success) { $gruppen += $d.Groups[1].Value }
  }
  $a = ($gruppen -join '').ToLower()
  if ($a.Length -ne 56) { throw "Adresse hat $($a.Length) statt 56 Zeichen: $a" }
  return $a
}
