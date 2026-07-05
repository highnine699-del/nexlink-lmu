; LMU Auto-Connect Inno Setup installer script
; This installer bundles LMU-Auto-Connect.exe and the icon, but does not include lmu_portal.cred.

[Setup]
AppName=LMU Auto-Connect
AppVersion=1.0.0.0
DefaultDirName={pf}\LMU Auto-Connect
DefaultGroupName=LMU Auto-Connect
OutputBaseFilename=LMU-Auto-Connect-Installer
OutputDir=.
Compression=lzma
SolidCompression=yes
SetupIconFile=wifi_icon.ico
PrivilegesRequired=admin
DisableProgramGroupPage=no
DirExistsWarning=no
WizardStyle=modern
UninstallDisplayIcon={app}\LMU-Auto-Connect.exe
InfoBeforeFile=README.txt

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "LMU-AutoConnect.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "wifi_icon.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "README.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\LMU Auto-Connect"; Filename: "{app}\LMU-AutoConnect.exe"; IconFilename: "{app}\wifi_icon.ico"
Name: "{userdesktop}\LMU Auto-Connect"; Filename: "{app}\LMU-AutoConnect.exe"; IconFilename: "{app}\wifi_icon.ico"; Tasks: desktopicon
Name: "{userstartup}\LMU Auto-Connect"; Filename: "{app}\LMU-AutoConnect.exe"; IconFilename: "{app}\wifi_icon.ico"; Tasks: startupicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional icons:"; Flags: unchecked
Name: "startupicon"; Description: "Start automatically when I log into Windows"; GroupDescription: "Additional icons:"; Flags: unchecked

[Run]
Filename: "{app}\LMU-AutoConnect.exe"; Description: "Launch LMU Auto-Connect"; Flags: nowait postinstall skipifsilent
