# Self-install: copy this unpacked pack into the shared RetComM toolchain cache
# and add latest\bin to the user PATH (idempotent).
#
#   .\install.ps1
#   .\install.ps1 -Force
# Or: install.bat

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$PackId = if ($env:RETCOMM_PACK_ID) { $env:RETCOMM_PACK_ID } else { "cmake-clang-v1" }
$PackRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$Cmake = Join-Path $PackRoot "bin\cmake.exe"
if (-not (Test-Path -LiteralPath $Cmake)) {
    throw "bin\cmake.exe missing — run this from the extracted pack root"
}

function Get-CacheRoot {
    if ($env:RETCOMM_TOOLCHAIN_CACHE) { return $env:RETCOMM_TOOLCHAIN_CACHE }
    if ($env:RETCOMM_DATA_HOME) { return (Join-Path $env:RETCOMM_DATA_HOME "toolchains\$PackId") }
    $local = $env:LOCALAPPDATA
    if (-not $local) { throw "LOCALAPPDATA is not set" }
    return (Join-Path $local "retcomm\toolchains\$PackId")
}

function Get-PackVersion([string]$Root) {
    $meta = Join-Path $Root "retcomm-toolchain.json"
    if (-not (Test-Path -LiteralPath $meta)) { return "offline" }
    try {
        $j = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
        $v = [string]$j.version
        if ([string]::IsNullOrWhiteSpace($v)) { return "offline" }
        return $v.Trim()
    } catch {
        return "offline"
    }
}

function Get-SanitizeTag([string]$Tag) {
    $s = ($Tag -replace '[^\w.\-]+', '_')
    if ([string]::IsNullOrWhiteSpace($s)) { return "offline" }
    return $s
}

function Get-UserPathEntries {
    $raw = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($raw)) { return New-Object System.Collections.Generic.List[string] }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in ($raw -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$list.Add($p.TrimEnd('\')) }
    }
    return $list
}

function Set-UserPathEntries([System.Collections.Generic.List[string]]$Entries) {
    $value = ($Entries -join ';')
    [Environment]::SetEnvironmentVariable("Path", $value, "User")
    # Refresh this process PATH idempotently (don't duplicate).
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $env:Path = (@($machine, $value) | Where-Object { $_ }) -join ';'
}

function Add-UserPathDir([string]$Dir) {
    $norm = $Dir.TrimEnd('\')
    $entries = Get-UserPathEntries
    $exists = $false
    foreach ($e in $entries) {
        if ($e -ieq $norm) { $exists = $true; break }
    }
    if (-not $exists) {
        [void]$entries.Add($norm)
        Set-UserPathEntries $entries
        Write-Host "Added to user PATH: $norm"
    } else {
        Write-Host "Already on user PATH: $norm"
        # Still refresh process env from registry so this session sees it if missing.
        $procParts = @($env:Path -split ';' | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
        $inProc = $false
        foreach ($p in $procParts) { if ($p -ieq $norm) { $inProc = $true; break } }
        if (-not $inProc) {
            $env:Path = "$norm;$env:Path"
        }
    }
}

function Set-LatestPointer([string]$CacheRoot, [string]$Dest) {
    $latest = Join-Path $CacheRoot "latest"
    if (Test-Path -LiteralPath $latest) {
        Remove-Item -LiteralPath $latest -Recurse -Force
    }
    try {
        New-Item -ItemType Junction -Path $latest -Target $Dest | Out-Null
    } catch {
        try {
            New-Item -ItemType SymbolicLink -Path $latest -Target $Dest | Out-Null
        } catch {
            Copy-Item -Recurse -Force -LiteralPath $Dest -Destination $latest
        }
    }
}

$cache = Get-CacheRoot
$ver = Get-PackVersion $PackRoot
$tag = Get-SanitizeTag $ver
$dest = Join-Path $cache $tag
$latest = Join-Path $cache "latest"
$binDir = Join-Path $latest "bin"

New-Item -ItemType Directory -Force -Path $cache | Out-Null

$skipCopy = $false
if ((Test-Path -LiteralPath $dest) -and -not $Force) {
    if (Test-Path -LiteralPath (Join-Path $dest "bin\cmake.exe")) {
        Write-Host "Already installed at $dest (pass -Force to replace)."
        $skipCopy = $true
    }
}

if (-not $skipCopy) {
    Write-Host "Installing $PackId $ver -> $dest"
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item -Path (Join-Path $PackRoot '*') -Destination $dest -Recurse -Force
}

Set-LatestPointer $cache $dest
Add-UserPathDir $binDir

[Environment]::SetEnvironmentVariable("RETCOMM_TOOLCHAIN_DIR", $latest, "User")
$env:RETCOMM_TOOLCHAIN_DIR = $latest

# Session convenience (env.bat-equivalent bits for this process).
# Host libs live under deps/ (1.0.9+) — never pack-root CMAKE_PREFIX_PATH / ZLIB_ROOT.
$deps = Join-Path $latest "deps"
if (Test-Path -LiteralPath (Join-Path $deps "include\zlib.h")) {
    $env:ZLIB_ROOT = $deps
} elseif (Test-Path -LiteralPath (Join-Path $latest "include\zlib.h")) {
    $env:ZLIB_ROOT = $latest
}
$sdl3Dir = $null
foreach ($root in @($deps, $latest)) {
    $sdl3Cfg = Join-Path $root "lib\cmake\SDL3\SDL3Config.cmake"
    $sdl3CfgAlt = Join-Path $root "lib\cmake\SDL3\SDL3-config.cmake"
    if ((Test-Path -LiteralPath $sdl3Cfg) -or (Test-Path -LiteralPath $sdl3CfgAlt)) {
        $sdl3Dir = Join-Path $root "lib\cmake\SDL3"
        break
    }
}
if ($null -ne $sdl3Dir) {
    $env:SDL3_DIR = $sdl3Dir
}

Write-Host ""
Write-Host "Installed $PackId $ver"
Write-Host "  Pack:  $dest"
Write-Host "  PATH:  $binDir  (user env + this session)"
Write-Host ""
Write-Host "Open a new terminal, then:"
Write-Host "  cmake --version"
Write-Host "  clang --version"
Write-Host ""
Write-Host "Uninstall later:"
Write-Host "  .\uninstall.ps1"
Write-Host "  (or uninstall.bat)"
