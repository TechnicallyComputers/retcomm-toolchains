# Install cmake-clang-v1 (Windows x64 / llvm-mingw UCRT) into the RetComM cache.
#
#   .\scripts\install_windows_x64.ps1
#   .\scripts\install_windows_x64.ps1 -FromZip $env:USERPROFILE\Downloads\cmake-clang-v1-windows-x64.zip
#   .\scripts\install_windows_x64.ps1 -Download -Force
#
# Layout (matches RetComM + standalone setup hosts):
#   %LOCALAPPDATA%\retcomm\toolchains\cmake-clang-v1\<tag>\

[CmdletBinding()]
param(
    [string]$FromZip = "",
    [switch]$Download,
    [switch]$Force,
    [string]$Prefix = "",
    [string]$Repo = $(if ($env:RETCOMM_TOOLCHAIN_REPO) { $env:RETCOMM_TOOLCHAIN_REPO } else { "TechnicallyComputers/retcomm-toolchains" })
)

$ErrorActionPreference = "Stop"
$PackId = "cmake-clang-v1"
$Asset = "$PackId-windows-x64.zip"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptRoot

function Get-PackCacheRoot {
    if ($Prefix) {
        if (Test-Path -LiteralPath $Prefix) {
            return (Resolve-Path -LiteralPath $Prefix).Path
        }
        return $Prefix
    }
    if ($env:RETCOMM_TOOLCHAIN_CACHE) { return $env:RETCOMM_TOOLCHAIN_CACHE }
    if ($env:RETCOMM_DATA_HOME) { return (Join-Path $env:RETCOMM_DATA_HOME "toolchains\$PackId") }
    $local = $env:LOCALAPPDATA
    if (-not $local) { throw "LOCALAPPDATA is not set" }
    return (Join-Path $local "retcomm\toolchains\$PackId")
}

function Test-PackUsable([string]$Root) {
    return (Test-Path -LiteralPath (Join-Path $Root "bin\cmake.exe"))
}

function Get-UnwrapPackRoot([string]$Path) {
    if (Test-PackUsable $Path) { return $Path }
    $kids = @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Name.StartsWith(".") })
    if ($kids.Count -eq 1 -and (Test-PackUsable $kids[0].FullName)) {
        return $kids[0].FullName
    }
    return $Path
}

function Get-PackVersion([string]$Root) {
    $meta = Join-Path $Root "retcomm-toolchain.json"
    if (-not (Test-Path -LiteralPath $meta)) { return "" }
    try {
        $j = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
        return [string]$j.version
    } catch {
        return ""
    }
}

function Get-SanitizeTag([string]$Tag) {
    $s = ($Tag -replace '[^\w.\-]+', '_')
    if ([string]::IsNullOrWhiteSpace($s)) { return "offline" }
    return $s
}

function Find-LocalDistZip {
    $cand = Join-Path $RepoRoot "dist\$Asset"
    if (Test-Path -LiteralPath $cand) { return $cand }
    $matches = @(Get-ChildItem -Path (Join-Path $RepoRoot "dist") -Filter "$PackId*windows*.zip" -ErrorAction SilentlyContinue)
    if ($matches.Count -eq 1) { return $matches[0].FullName }
    return $null
}

function Get-DownloadZip([string]$Dest) {
    $dir = Split-Path -Parent $Dest
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-Host "Downloading $Asset from $Repo…"
    $url = "https://github.com/$Repo/releases/latest/download/$Asset"
    $partial = "$Dest.partial"
    if (Get-Command gh -ErrorAction SilentlyContinue) {
        & gh release download -R $Repo -p $Asset -D $dir --clobber
        $downloaded = Join-Path $dir $Asset
        if ($downloaded -ne $Dest) {
            Move-Item -Force -LiteralPath $downloaded -Destination $Dest
        }
    } else {
        $headers = @{ "User-Agent" = "retcomm-toolchains-install" }
        $token = $env:GH_TOKEN; if (-not $token) { $token = $env:GITHUB_TOKEN }
        if ($token) { $headers["Authorization"] = "Bearer $token" }
        Invoke-WebRequest -Uri $url -OutFile $partial -Headers $headers
        Move-Item -Force -LiteralPath $partial -Destination $Dest
    }
}

function Set-LatestPointer([string]$CacheRoot, [string]$PackRoot) {
    $latest = Join-Path $CacheRoot "latest"
    if (Test-Path -LiteralPath $latest) {
        Remove-Item -LiteralPath $latest -Recurse -Force
    }
    try {
        New-Item -ItemType SymbolicLink -Path $latest -Target $PackRoot | Out-Null
    } catch {
        Copy-Item -Recurse -Force -LiteralPath $PackRoot -Destination $latest
    }
}

function Write-PackStamp([string]$Dest, [string]$Tag, [string]$AssetName) {
    $obj = [ordered]@{
        id           = $PackId
        tag          = $Tag
        asset        = $AssetName
        github       = $Repo
        installed_by = "retcomm-toolchains/scripts/install"
    }
    ($obj | ConvertTo-Json) + "`n" | Set-Content -LiteralPath (Join-Path $Dest ".retcomm-pack.json") -Encoding utf8
}

function Write-DevHowto([string]$PackRoot, [string]$Ver) {
    Write-Host ""
    Write-Host "Installed $PackId $Ver -> $PackRoot"
    Write-Host ""
    Write-Host "This is the shared RetComM toolchain cache. RetComM, title setup wizards, and"
    Write-Host "standalone ensure-toolchain will reuse it (no second download)."
    Write-Host ""
    Write-Host "Activate for recomp / CMake / Ninja development (cmd.exe):"
    Write-Host ""
    Write-Host "  call `"$PackRoot\env.bat`""
    Write-Host "  cmake --version"
    Write-Host "  clang --version"
    Write-Host ""
    Write-Host "Optional (PowerShell / hosts that honor it):"
    Write-Host "  `$env:RETCOMM_TOOLCHAIN_DIR = '$PackRoot'"
    Write-Host ""
}

$cacheRoot = Get-PackCacheRoot
New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null

$zipPath = $null
if ($FromZip) {
    $zipPath = (Resolve-Path -LiteralPath $FromZip).Path
} elseif ($Download) {
    $zipPath = Join-Path $cacheRoot ".download\$Asset"
    Get-DownloadZip $zipPath
} else {
    $local = Find-LocalDistZip
    if ($local) {
        $zipPath = $local
        Write-Host "Using local pack: $zipPath"
    } else {
        $zipPath = Join-Path $cacheRoot ".download\$Asset"
        Get-DownloadZip $zipPath
    }
}

$staging = Join-Path $cacheRoot ".staging-install"
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Force -Path $staging | Out-Null
Write-Host "Extracting $(Split-Path -Leaf $zipPath)…"
Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force

$root = Get-UnwrapPackRoot $staging
if (-not (Test-PackUsable $root)) {
    throw "zip missing bin\cmake.exe: $zipPath"
}

$ver = Get-PackVersion $root
$tag = Get-SanitizeTag $(if ($ver) { $ver } else { "offline" })
$dest = Join-Path $cacheRoot $tag

if ((Test-Path -LiteralPath $dest) -and -not $Force) {
    $existing = Get-UnwrapPackRoot $dest
    if (Test-PackUsable $existing) {
        Write-Host "Already installed at $dest (pass -Force to replace)."
        Set-LatestPointer $cacheRoot $existing
        Write-DevHowto $existing $(if ($ver) { $ver } else { $tag })
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        exit 0
    }
}

if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
if ($root -eq $staging) {
    Move-Item -LiteralPath $staging -Destination $dest
} else {
    Move-Item -LiteralPath $root -Destination $dest
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$root = Get-UnwrapPackRoot $dest
Write-PackStamp $dest $tag (Split-Path -Leaf $zipPath)
Set-LatestPointer $cacheRoot $root

& (Join-Path $root "bin\cmake.exe") --version | Select-Object -First 1
Write-DevHowto $root $(if ($ver) { $ver } else { $tag })
