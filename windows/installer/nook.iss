; Nook 的 Windows 安裝器（Inno Setup 7）。
;
; 不要直接編這支：scripts\package_windows.ps1 會先把 Release 目錄、VC++ runtime DLL、
; LICENSE 排進暫存資料夾，再用下面這些定義呼叫 ISCC：
;
;   iscc /DAppVersion=1.0.0+1 /DAppVersionNumeric=1.0.0.1 /DSourceDir=<暫存資料夾>
;        /DOutputDir=<dist> /DOutputBaseFilename=Nook-1.0.0-1-windows-x64-setup
;        windows\installer\nook.iss
;
; 保險庫（%APPDATA%\tw.com.jetopto\Nook\）不屬於這個安裝器：這裡不安裝、不刪除那個目錄，
; 所以升級、重裝、解除安裝都不會動到資料。[UninstallDelete] 刻意留空，不要把 {userappdata} 加進去。

#if VER < EncodeVer(7, 0, 0)
  #error 需要 Inno Setup 7 以上（SetupArchitecture 是 7.0 才有的指令）
#endif

#ifndef AppVersion
  #error 缺 /DAppVersion（例如 1.0.0+1）
#endif
#ifndef AppVersionNumeric
  #error 缺 /DAppVersionNumeric（四段數字，例如 1.0.0.1）
#endif
#ifndef SourceDir
  #error 缺 /DSourceDir（排好的 Release 目錄，要有 nook.exe）
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "Nook-setup"
#endif

#if !FileExists(AddBackslash(SourceDir) + "nook.exe")
  #error SourceDir 裡沒有 nook.exe
#endif

[Setup]
; AppId 是 Windows 認「同一個程式」的依據：升級、解除安裝都靠它。發佈後永遠不能改。
AppId={{0B98D084-6C56-4575-8B63-54A36D8E034A}
AppName=Nook
AppVersion={#AppVersion}
AppVerName=Nook {#AppVersion}
AppPublisher=tw.com.jetopto
AppPublisherURL=https://github.com/SheldonChangL/nook
AppSupportURL=https://github.com/SheldonChangL/nook/issues
VersionInfoVersion={#AppVersionNumeric}
VersionInfoProductName=Nook
VersionInfoProductVersion={#AppVersionNumeric}

; Inno Setup 7 預設產生 32 位元安裝器；Nook 只有 x64 版，安裝器也做成 x64。
; x64compatible 同時涵蓋 x64 Windows 與能模擬 x64 的 Arm64 Windows 11（後者未驗證）。
SetupArchitecture=x64
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Flutter 桌面版最低支援 Windows 10。
MinVersion=10.0

; 只裝給目前的使用者（%LOCALAPPDATA%\Programs\Nook，不必系統管理員權限）。不開放在安裝畫面改成
; 裝給所有使用者：兩種模式的登錄分在 HKCU／HKLM，Inno Setup 認不出另一種模式的舊安裝，會變成裝兩份。
; 管理員要部署給所有使用者，可明確用命令列 /ALLUSERS（Program Files，要 UAC），之後升級也要一直用 /ALLUSERS。
; 保險庫永遠是各使用者自己的 %APPDATA%。
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline
DefaultDirName={autopf}\Nook
DisableProgramGroupPage=yes
UsedUserAreasWarning=no

; 升級或解除安裝時，Nook 還開著就請使用者關掉（Restart Manager），不自動重開。
CloseApplications=yes
RestartApplications=no

SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\nook.exe
UninstallDisplayName=Nook
WizardStyle=modern
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}

; 沒有程式碼簽章憑證：安裝器與 nook.exe 都未簽章，SmartScreen 會警告。
; 之後有憑證時在這裡加 SignTool=，並在建置機設定對應的 Sign Tool；憑證不得放進 repo。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[InstallDelete]
; 舊版留下、新版已不再需要的檔案會讓程式載入錯的資產或外掛。只清安裝目錄裡的這兩類，
; 保險庫不在安裝目錄裡。
Type: filesandordirs; Name: "{app}\data"
Type: files; Name: "{app}\*.dll"

[Files]
; 整份 Release 目錄（nook.exe、flutter_windows.dll、外掛 DLL、data\）加 VC++ runtime DLL 與 LICENSE.txt。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Nook"; Filename: "{app}\nook.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Nook"; Filename: "{app}\nook.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\nook.exe"; Description: "{cm:LaunchProgram,Nook}"; Flags: nowait postinstall skipifsilent
