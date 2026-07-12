; ============================================================================
;  Instalador do Odin Video Editor (Inno Setup 6.3+)
;  Empacota: editor.exe + ffmpeg.exe + ffprobe.exe (ao lado do exe, achados via
;  PATH no startup por init_paths) + a licença GPL do ffmpeg.
;
;  Como gerar o instalador:
;    1) Instale o Inno Setup 6 (https://jrsoftware.org/isdl.php)
;    2) Compile este arquivo:
;         "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" setup.iss
;       (ou abra setup.iss no Inno Setup e clique em Build > Compile)
;    3) O Setup sai em:  dist\Output\OdinVideoEditor-Setup.exe
; ============================================================================

#define MyAppName "Odin Video Editor"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "ezekuiel100"
#define MyAppExeName "editor.exe"

[Setup]
; AppId identifica o app para atualizações/desinstalação — NÃO mude entre versões.
AppId={{A7E4C1F2-3B6D-4E8A-9C2F-1D5B7E9A0C34}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; Só faz sentido em Windows 64-bit (o ffmpeg e o editor são x64).
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=dist\Output
OutputBaseFilename=OdinVideoEditor-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Ícone do próprio instalador (o atalho e o .exe usam o ícone embutido no editor.exe).
SetupIconFile=icon.ico
; Mostra a licença GPL do ffmpeg empacotado (obrigação de redistribuição).
LicenseFile=dist\LICENSE-ffmpeg.txt
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "editor.exe";               DestDir: "{app}"; Flags: ignoreversion
Source: "dist\ffmpeg.exe";          DestDir: "{app}"; Flags: ignoreversion
Source: "dist\ffprobe.exe";         DestDir: "{app}"; Flags: ignoreversion
Source: "dist\LICENSE-ffmpeg.txt";  DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}";               Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Desinstalar {#MyAppName}";   Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}";         Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent
