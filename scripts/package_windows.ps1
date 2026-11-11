# 在 Windows 上編 Release 版，打成安裝器（Setup.exe）與內測用的 ZIP。
#
#   powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1 -NoBuild
#   powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1 -SkipZip
#   powershell -ExecutionPolicy Bypass -File scripts\package_windows.ps1 -SkipInstaller
#
# 需要（建置機）：Flutter、Visual Studio 2022 的「使用 C++ 的桌面開發」工作負載、
# Inno Setup 7（做安裝器才要；ISCC.exe 找法見 Find-Iscc，或用 -Iscc 指定）。
# 產出（dist\）：
#   Nook-<版本>-windows-x64-setup.exe   安裝器（windows\installer\nook.iss）
#   Nook-<版本>-windows-x64.zip         內測用，解壓即用
#   SHA256SUMS-windows.txt              上面兩個檔案的 SHA256（sha256sum 格式）
# <版本> 是 pubspec 的 version 把 + 換成 -（1.0.0+1 → 1.0.0-1），檔名放上網頁或 URL 才不會被改寫。
#
# 為什麼是整個資料夾而不是單一 .exe：nook.exe 要跟 flutter_windows.dll、外掛 DLL、
# data\（flutter_assets、icudtl.dat、app.so）放在一起才跑得起來。少一個就開不了。
# 安裝器與 ZIP 收的是同一份排好的資料夾。
#
# Visual C++ runtime（msvcp140.dll、vcruntime140.dll、vcruntime140_1.dll）會從
# 建置機的 System32 複製進來放在 nook.exe 旁邊（app-local 部署），乾淨的 Windows 不必另裝
# VC++ Redistributable。代價是這三個 DLL 不會跟著 Windows Update 更新，要靠出新版帶新的。
# 不想帶就加 -NoVcRuntime，改由使用者自己安裝 VC++ Redistributable。
#
# 安裝器與 ZIP 都沒有簽章，SmartScreen 會警告。簽章需要程式碼簽章憑證，這支腳本不處理。
#
# 保險庫放在 %APPDATA%\tw.com.jetopto\Nook\vault\，不在安裝目錄裡，
# 所以升級、解除安裝、換 ZIP 資料夾都不會動到資料。
[CmdletBinding()]
param(
  [switch]$NoBuild,
  [switch]$NoVcRuntime,
  [switch]$SkipZip,
  [switch]$SkipInstaller,
  # ISCC.exe 的完整路徑；不給就依序找環境變數 NOOK_ISCC、PATH、預設安裝位置。
  [string]$Iscc
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
  throw '這支要在 Windows 上跑（flutter build windows 不能跨平台編）'
}

# 32 位元的 PowerShell 會被 WOW64 把 System32 轉到 SysWOW64，複製到的是 32 位元的
# VC runtime，放在 x64 的 nook.exe 旁邊會開不起來。
if (-not [Environment]::Is64BitProcess) {
  throw '請用 64 位元的 PowerShell 執行（目前是 32 位元行程）'
}

$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $repo

$versionLine = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $versionLine) { throw 'pubspec.yaml 找不到 version' }
$version = $versionLine.Matches[0].Groups[1].Value
# Windows 版本資訊要四段數字：1.0.0+1 → 1.0.0.1（沒有 +build 就補 0）。
if ($version -notmatch '^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$') {
  throw "pubspec.yaml 的 version 不是 X.Y.Z 或 X.Y.Z+N：$version"
}
$buildNumber = if ($Matches[4]) { $Matches[4] } else { '0' }
$versionParts = @($Matches[1], $Matches[2], $Matches[3], $buildNumber)
# Windows 版本資訊每段最多 65535（例如 20261111 這種日期式 build number 會讓 ISCC 失敗）。
foreach ($part in $versionParts) {
  if ([long]$part -gt 65535) { throw "版本號每段要 ≤ 65535，Windows 版本資訊放不下：$version" }
}
$versionNumeric = $versionParts -join '.'
$fileVersion = $version -replace '\+', '-'

function Find-Iscc {
  if ($Iscc) {
    if (-not (Test-Path $Iscc)) { throw "找不到 -Iscc 指定的 $Iscc" }
    return $Iscc
  }
  if ($env:NOOK_ISCC) {
    if (-not (Test-Path $env:NOOK_ISCC)) { throw "找不到 NOOK_ISCC 指定的 $($env:NOOK_ISCC)" }
    return $env:NOOK_ISCC
  }
  $onPath = Get-Command 'iscc.exe' -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  foreach ($candidate in @(
      (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
      (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'))) {
    if ($candidate -and (Test-Path $candidate)) { return $candidate }
  }
  throw '找不到 Inno Setup 7 的 ISCC.exe。安裝 Inno Setup 7、用 -Iscc 指定，或加 -SkipInstaller 只做 ZIP'
}

if ($SkipZip -and $SkipInstaller) { throw '-SkipZip 和 -SkipInstaller 不能同時給，那就什麼都沒產出' }
# 先找 ISCC，免得編了好幾分鐘才發現沒裝。
$isccPath = if ($SkipInstaller) { $null } else { Find-Iscc }

if (-not $NoBuild) {
  Write-Host '==> 編 Release'
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失敗（$LASTEXITCODE）" }
}

$bundle = Join-Path $repo 'build\windows\x64\runner\Release'
foreach ($required in @('nook.exe', 'flutter_windows.dll', 'data\icudtl.dat', 'data\app.so', 'data\flutter_assets')) {
  if (-not (Test-Path (Join-Path $bundle $required))) {
    throw "Release 目錄缺少 $required，先編譯：$bundle"
  }
}

$stageRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("nook-package-" + [guid]::NewGuid())
$stage = Join-Path $stageRoot 'Nook'
try {
  Write-Host '==> 排檔案'
  New-Item -ItemType Directory -Path $stage | Out-Null
  # 只收 Release 目錄；build\ 的中間產物、.pdb、.lib/.exp 不進包。
  Copy-Item -Path (Join-Path $bundle '*') -Destination $stage -Recurse
  Get-ChildItem -Path $stage -Recurse -Include '*.pdb', '*.lib', '*.exp', '*.ilk' | Remove-Item -Force
  Copy-Item -Path (Join-Path $repo 'LICENSE') -Destination (Join-Path $stage 'LICENSE.txt')

  if (-not $NoVcRuntime) {
    $system32 = Join-Path $env:WINDIR 'System32'
    foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
      $source = Join-Path $system32 $dll
      if (-not (Test-Path $source)) {
        throw "建置機找不到 $source。先安裝 VC++ Redistributable（x64），或加 -NoVcRuntime"
      }
      Copy-Item -Path $source -Destination $stage
    }
  }

  $dist = Join-Path $repo 'dist'
  New-Item -ItemType Directory -Path $dist -Force | Out-Null
  $outputs = @()

  if (-not $SkipZip) {
    $zip = Join-Path $dist "Nook-$fileVersion-windows-x64.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Write-Host "==> 壓縮 $zip"
    Compress-Archive -Path $stage -DestinationPath $zip
    $outputs += $zip
  }

  if (-not $SkipInstaller) {
    $setupBase = "Nook-$fileVersion-windows-x64-setup"
    $setup = Join-Path $dist "$setupBase.exe"
    if (Test-Path $setup) { Remove-Item $setup -Force }
    Write-Host "==> 安裝器 $setup（$isccPath）"
    # Inno Setup 7 把警告寫到 stderr；Windows PowerShell 5.1 在 stderr 被轉向時會把它當成
    # 終止錯誤。這一段只看退出碼。
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
      & $isccPath /Q `
        "/DAppVersion=$version" `
        "/DAppVersionNumeric=$versionNumeric" `
        "/DSourceDir=$stage" `
        "/DOutputDir=$dist" `
        "/DOutputBaseFilename=$setupBase" `
        (Join-Path $repo 'windows\installer\nook.iss')
      $isccExit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    if ($isccExit -ne 0) { throw "ISCC 失敗（$isccExit）" }
    if (-not (Test-Path $setup)) { throw "ISCC 回報成功但沒有 $setup" }
    $outputs += $setup
  }

  Write-Host '==> 內容'
  Get-ChildItem -Path $stage -Recurse -File |
    ForEach-Object { $_.FullName.Substring($stage.Length + 1) } |
    Sort-Object |
    ForEach-Object { Write-Host "  $_" }

  # sha256sum 格式（小寫雜湊、兩個空白、檔名），Linux／macOS 可直接 sha256sum -c／shasum -a 256 -c。
  $sums = Join-Path $dist 'SHA256SUMS-windows.txt'
  $lines = foreach ($file in $outputs) {
    $hash = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLowerInvariant()
    Write-Host "好了：$file"
    Write-Host "  SHA256：$hash"
    "$hash  $(Split-Path -Leaf $file)"
  }
  # 不用 Set-Content -Encoding UTF8：Windows PowerShell 5.1 會加 BOM，sha256sum -c 讀不懂。
  [System.IO.File]::WriteAllText($sums, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "校驗檔：$sums"
  if (-not $SkipInstaller) { Write-Host '安裝：執行 Nook-*-setup.exe（未簽章，SmartScreen 要按「其他資訊」→「仍要執行」）' }
  if (-not $SkipZip) { Write-Host 'ZIP：解壓縮後執行 Nook\nook.exe（整個資料夾一起搬，不能只拿 nook.exe）' }
}
finally {
  if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
}
