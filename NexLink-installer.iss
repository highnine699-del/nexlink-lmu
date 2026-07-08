; NexLink Inno Setup installer script
; This installer bundles NexLink.exe and the icon, but does not include lmu_portal.cred.

[Setup]
AppName=NexLink
AppVersion=1.3.9.0
DefaultDirName={pf}\NexLink
DefaultGroupName=NexLink
OutputBaseFilename=NexLink-Installer
OutputDir=.
Compression=lzma
SolidCompression=yes
SetupIconFile=wifi_icon.ico
PrivilegesRequired=admin
DisableProgramGroupPage=no
DirExistsWarning=no
WizardStyle=modern
UninstallDisplayIcon={app}\NexLink.exe
InfoBeforeFile=README.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "NexLink.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "wifi_icon.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.txt"; DestDir: "{app}"; Flags: ignoreversion

[UninstallDelete]
Type: files; Name: "{app}\lmu_portal.cred"
Type: files; Name: "{app}\lmu_autoconnect.log"
Type: files; Name: "{app}\nexlink_pro_license.cred"
Type: files; Name: "{app}\nexlink_theme.txt"

[Icons]
Name: "{group}\NexLink"; Filename: "{app}\NexLink.exe"; IconFilename: "{app}\wifi_icon.ico"
Name: "{commondesktop}\NexLink"; Filename: "{app}\NexLink.exe"; IconFilename: "{app}\wifi_icon.ico"; Tasks: desktopicon
Name: "{commonstartup}\NexLink"; Filename: "{app}\NexLink.exe"; IconFilename: "{app}\wifi_icon.ico"; Tasks: startupicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked
Name: "startupicon"; Description: "Start automatically when I log into Windows"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\NexLink.exe"; Description: "Launch NexLink"; Flags: nowait postinstall skipifsilent shellexec
