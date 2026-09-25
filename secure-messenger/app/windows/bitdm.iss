; BitDM — Windows-Installer
;
; Bauen (nach `flutter build windows --release`):
;   & "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" windows\bitdm.iss
; Ergebnis: releases\bitdm-windows-setup-1.6.0.exe
;
; WARUM OHNE ADMINRECHTE. `PrivilegesRequired=lowest` installiert nach
; %LOCALAPPDATA% statt nach "Program Files". Das kostet nichts und erspart die
; UAC-Abfrage — ein Messenger braucht keine Rechte am ganzen System, und wer
; nach Adminrechten fragt, ohne sie zu brauchen, hat die Begruendung schon
; verloren.
;
; WARUM KEIN AUTOSTART. Die App bringt einen Empfangstakt mit, den der Nutzer
; in den Einstellungen waehlt. Ein Installer, der sich selbst in den Autostart
; schreibt, nimmt diese Wahl vorweg.
;
; NICHT SIGNIERT, und das laesst sich hier nicht besser machen: Windows-
; Codesigning braucht ein Authenticode-Zertifikat einer Zertifizierungsstelle
; (kostenpflichtig, jaehrlich). Der Android-Schluessel taugt dafuer nicht.
; SmartScreen wird also warnen — genau wie Play Protect bei der APK. Der Weg
; dagegen ist derselbe: den sha256 der Datei veroeffentlichen, damit die Warnung
; pruefbar wird statt geglaubt.

#define Name      "BitDM"
; Die Fassung kommt beim Bauen mit: ISCC /DVersion=1.8.0 windowsitdm.iss
#ifndef Version
  #define Version "0.0.0-lokal"
#endif
#define Publisher "BitDM"
#define ExeName   "bitdm.exe"

[Setup]
AppId={{7E2A9C41-5B3D-4F18-9A6C-BD1E0F3A8C52}
AppName={#Name}
AppVersion={#Version}
AppVerName={#Name} {#Version}
AppPublisher={#Publisher}
AppPublisherURL=https://bitdm.net
AppSupportURL=https://bitdm.net/docs
DefaultDirName={autopf}\{#Name}
DefaultGroupName={#Name}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=..\..\releases
OutputBaseFilename=bitdm-windows-setup-{#Version}
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#ExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Beim Aktualisieren nicht nach dem Zielordner fragen — die alte Fassung wird
; ersetzt, und eine zweite Installation daneben waere eine zweite Identitaet.
DisableDirPage=auto

[Languages]
Name: "deutsch"; MessagesFile: "compiler:Languages\German.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Der ganze Bau-Ausgang. Die DLLs und `data\` MUESSEN neben der .exe liegen —
; sqlite3mc.dll ist die verschluesselte Datenbank, webcrypto.dll die Krypto,
; und in data\app.so steckt der eigentliche Dart-Code.
Source: "..\build\windows\x64\runner\Release\{#ExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\windows\x64\runner\Release\*";          DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#Name}";           Filename: "{app}\{#ExeName}"
Name: "{autodesktop}\{#Name}";     Filename: "{app}\{#ExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ExeName}"; Description: "{cm:LaunchProgram,{#Name}}"; \
  Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Der Bau-Ausgang, nicht die Nutzerdaten. Identitaet und Nachrichten liegen in
; %APPDATA%\com.bitdm und BLEIBEN beim Deinstallieren liegen — wer die App neu
; installiert, findet seine Unterhaltungen wieder. Wer sie wirklich loswerden
; will, benutzt in der App "alles loeschen"; das ist der Weg, der auch die
; Anhaenge und den Schluesselspeicher mitnimmt.
Type: filesandordirs; Name: "{app}"
