; Framelet Windows installer (Inno Setup 6)
; Build: iscc /DAppVersion=x.y.z framelet.iss

#ifndef AppVersion
#define AppVersion "0.1.0"
#endif

[Setup]
AppId={{7A1C0E52-93D4-4B6A-9F18-2C5D8E1B0A44}
AppName=拾帧 Framelet
AppVersion={#AppVersion}
AppVerName=拾帧 Framelet {#AppVersion}
AppPublisher=Framelet
DefaultDirName={autopf}\Framelet
DefaultGroupName=拾帧 Framelet
UninstallDisplayIcon={app}\framelet.exe
OutputDir=Output
OutputBaseFilename=FrameletSetup-{#AppVersion}-x64
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
RestartApplications=no

[Languages]
; ChineseSimplified.isl 内嵌于仓库（choco 的 Inno Setup 不带简中翻译），
; 来源：jrsoftware/issrc is-6_5_1 tag（Files/Languages/Unofficial）
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\拾帧 Framelet"; Filename: "{app}\framelet.exe"
Name: "{group}\卸载拾帧 Framelet"; Filename: "{uninstallexe}"
Name: "{autodesktop}\拾帧 Framelet"; Filename: "{app}\framelet.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\framelet.exe"; Description: "{cm:LaunchProgram,拾帧 Framelet}"; Flags: nowait postinstall skipifsilent
