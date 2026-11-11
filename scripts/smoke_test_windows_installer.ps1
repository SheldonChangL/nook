# 在 Windows 上實際跑一遍 Nook 安裝器：安裝 → 檢查檔案與捷徑 → 啟動 → 覆蓋安裝（升級路徑）→
# 解除安裝 → 確認 %APPDATA% 的資料還在。CI（.github/workflows/windows-installer.yml）與測試機都用這支。
#
#   powershell -ExecutionPolicy Bypass -File scripts\smoke_test_windows_installer.ps1 `
#     -Installer dist\Nook-1.0.0-1-windows-x64-setup.exe
#   # 從上一版升級：
#   ... -PreviousInstaller <舊版 setup.exe> -Installer <新版 setup.exe>
#
# 只裝給目前使用者（/CURRENTUSER），不需要系統管理員權限。
# 這台機器若已經裝了 Nook，腳本會拒絕執行（它最後會解除安裝），除非加 -AllowExistingInstall。
# 不會建立或讀取保險庫內容：啟動只停在建立／解鎖畫面，檢查的是 nook.lock 出現在資料目錄。
# 測試在資料目錄放一個 smoke-sentinel-*.txt 確認解除安裝不會刪資料，結束時自己清掉。
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [string]$PreviousInstaller,
  [switch]$AllowExistingInstall,
  [int]$LaunchTimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') { throw '這支要在 Windows 上跑' }

# 與 windows\installer\nook.iss 的 AppId 相同；Inno Setup 在後面加 _is1 當解除安裝登錄機碼名稱。
$appId = '{0B98D084-6C56-4575-8B63-54A36D8E034A}'
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\${appId}_is1"
# path_provider_windows：%APPDATA%\<CompanyName>\<ProductName>（windows\runner\Runner.rc）。
$dataDir = Join-Path $env:APPDATA 'tw.com.jetopto\Nook'
$startMenuLink = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Nook.lnk'
$logDir = Join-Path ([System.IO.Path]::GetTempPath()) ("nook-smoke-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $logDir | Out-Null

function Pass([string]$message) { Write-Host "PASS  $message" }
function Fail([string]$message) { throw "FAIL  $message（安裝記錄在 $logDir）" }

function Invoke-Setup([string]$path, [string]$label) {
  $resolved = (Resolve-Path $path).Path
  $log = Join-Path $logDir "$label.log"
  $proc = Start-Process -FilePath $resolved -Wait -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER', "/LOG=`"$log`"")
  if ($proc.ExitCode -ne 0) { Fail "$label：安裝器退出碼 $($proc.ExitCode)" }
  Pass "$label：安裝器退出碼 0"
}

function Get-InstallDir {
  if (-not (Test-Path $uninstallKey)) { Fail "找不到解除安裝登錄 $uninstallKey" }
  $dir = (Get-ItemProperty -Path $uninstallKey).InstallLocation
  if (-not $dir) { Fail '解除安裝登錄沒有 InstallLocation' }
  return $dir.TrimEnd('\')
}

function Assert-Installed([string]$label) {
  $dir = Get-InstallDir
  foreach ($required in @(
      'nook.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\app.so', 'data\flutter_assets',
      'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'LICENSE.txt')) {
    if (-not (Test-Path (Join-Path $dir $required))) { Fail "$label：安裝目錄缺 $required（$dir）" }
  }
  if (Test-Path (Join-Path $dir 'vault')) { Fail "$label：安裝目錄裡出現 vault\，保險庫不該在這裡" }
  Pass "$label：$dir 有完整 Release 目錄與 VC++ runtime"

  if (-not (Test-Path $startMenuLink)) { Fail "$label：開始功能表沒有 $startMenuLink" }
  $target = (New-Object -ComObject WScript.Shell).CreateShortcut($startMenuLink).TargetPath
  if ($target -ne (Join-Path $dir 'nook.exe')) { Fail "$label：捷徑指向 $target，不是 $dir\nook.exe" }
  Pass "$label：開始功能表捷徑指向 nook.exe"
  return $dir
}

if ((Test-Path $uninstallKey) -and -not $AllowExistingInstall) {
  throw '這台機器已經裝了 Nook（目前使用者）。這支測試最後會解除安裝；確定要跑就加 -AllowExistingInstall'
}
if (Get-Process -Name 'nook' -ErrorAction SilentlyContinue) {
  throw 'Nook 正在執行，先關掉再測'
}

New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
$sentinel = Join-Path $dataDir ("smoke-sentinel-" + [guid]::NewGuid() + '.txt')
Set-Content -Path $sentinel -Value 'Nook installer smoke test; safe to delete.'

$nook = $null
try {
  if ($PreviousInstaller) {
    Invoke-Setup $PreviousInstaller 'previous'
    Assert-Installed 'previous' | Out-Null
  }

  Invoke-Setup $Installer 'install'
  $dir = Assert-Installed 'install'

  # 啟動：程式一開就在資料目錄獨占 nook.lock（lib/app/app_state.dart），用它確認
  # 1) 程式真的跑起來沒有立刻因缺 DLL 結束，2) 資料目錄就是文件寫的 %APPDATA% 路徑。
  # 前面已確認 Nook 沒在執行，舊的 nook.lock 只是殘留檔，先刪掉才看得出這次有沒有建立。
  $lock = Join-Path $dataDir 'nook.lock'
  if (Test-Path $lock) { Remove-Item $lock -Force }
  $nook = Start-Process -FilePath (Join-Path $dir 'nook.exe') -WorkingDirectory $dir -PassThru
  # 先取一次 Handle，結束後 ExitCode 才讀得到（否則常是空的）。
  $null = $nook.Handle
  $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
  while (-not (Test-Path $lock) -and (Get-Date) -lt $deadline) {
    if ($nook.HasExited) { Fail "nook.exe 啟動後就結束了（退出碼 $($nook.ExitCode)）" }
    Start-Sleep -Milliseconds 500
  }
  if (-not (Test-Path $lock)) { Fail "$LaunchTimeoutSeconds 秒內 $lock 沒有出現" }
  Start-Sleep -Seconds 3
  if ($nook.HasExited) { Fail "nook.exe 啟動後結束了（退出碼 $($nook.ExitCode)）" }
  Pass "nook.exe 啟動並在 $dataDir 建立 nook.lock"
  Stop-Process -Id $nook.Id -Force
  $nook.WaitForExit()
  $nook = $null

  Invoke-Setup $Installer 'reinstall'
  Assert-Installed 'reinstall' | Out-Null
  if (-not (Test-Path $sentinel)) { Fail '覆蓋安裝後資料目錄的 sentinel 不見了' }
  Pass '覆蓋安裝後資料目錄完好'

  $uninstaller = Join-Path $dir 'unins000.exe'
  if (-not (Test-Path $uninstaller)) { Fail "找不到 $uninstaller" }
  $proc = Start-Process -FilePath $uninstaller -Wait -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$(Join-Path $logDir 'uninstall.log')`"")
  if ($proc.ExitCode -ne 0) { Fail "解除安裝退出碼 $($proc.ExitCode)" }
  # 解除安裝程式會把自己複製到暫存目錄再跑，原本的行程可能先結束；等程式、登錄、捷徑、
  # unins000.exe（最後才刪）全部不見才算清完。
  $deadline = (Get-Date).AddSeconds(120)
  while (((Test-Path (Join-Path $dir 'nook.exe')) -or (Test-Path $uninstallKey) -or
          (Test-Path $startMenuLink) -or (Test-Path $uninstaller)) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
  }
  if (Test-Path (Join-Path $dir 'nook.exe')) { Fail '解除安裝後 nook.exe 還在' }
  if (Test-Path $uninstallKey) { Fail '解除安裝後登錄機碼還在' }
  if (Test-Path $startMenuLink) { Fail '解除安裝後開始功能表捷徑還在' }
  Pass '解除安裝移除了程式、捷徑與登錄'
  if (-not (Test-Path $sentinel)) { Fail '解除安裝刪掉了資料目錄裡的檔案' }
  Pass "解除安裝保留了 $dataDir"

  Write-Host '全部通過'
}
finally {
  if ($nook -and -not $nook.HasExited) { Stop-Process -Id $nook.Id -Force }
  if (Test-Path $sentinel) { Remove-Item $sentinel -Force }
}
