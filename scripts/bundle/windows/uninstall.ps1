# Remove this toolchain from the shared RetComM cache and from the user PATH.
#
#   .\uninstall.ps1
#   .\uninstall.ps1 -AllVersions
# Or: uninstall.bat

[CmdletBinding()]
param(
    [switch]$AllVersions
)

$ErrorActionPreference = "Stop"
$PackId = if ($env:RETCOMM_PACK_ID) { $env:RETCOMM_PACK_ID } else { "cmake-clang-v1" }
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Get-CacheRoot {
    if ($env:RETCOMM_TOOLCHAIN_CACHE) { return $env:RETCOMM_TOOLCHAIN_CACHE }
    if ($env:RETCOMM_DATA_HOME) { return (Join-Path $env:RETCOMM_DATA_HOME "toolchains\$PackId") }
    $local = $env:LOCALAPPDATA
    if (-not $local) { throw "LOCALAPPDATA is not set" }
    return (Join-Path $local "retcomm\toolchains\$PackId")
}

function Get-PackVersion([string]$Root) {
    $meta = Join-Path $Root "retcomm-toolchain.json"
    if (-not (Test-Path -LiteralPath $meta)) { return "" }
    try {
        $j = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json
        return ([string]$j.version).Trim()
    } catch {
        return ""
    }
}

function Get-SanitizeTag([string]$Tag) {
    if ([string]::IsNullOrWhiteSpace($Tag)) { return "" }
    $s = ($Tag -replace '[^\w.\-]+', '_')
    return $s
}

function Get-UserPathEntries {
    $raw = [Environment]::GetEnvironmentVariable("Path", "User")
    $list = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($raw)) { return $list }
    foreach ($p in ($raw -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($p)) { [void]$list.Add($p.TrimEnd('\')) }
    }
    return $list
}

function Set-UserPathEntries([System.Collections.Generic.List[string]]$Entries) {
    $value = ($Entries -join ';')
    [Environment]::SetEnvironmentVariable("Path", $value, "User")
    $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $env:Path = (@($machine, $value) | Where-Object { $_ }) -join ';'
}

function Remove-UserPathDir([string]$Dir) {
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    $norm = $Dir.TrimEnd('\')
    $entries = Get-UserPathEntries
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = $false
    foreach ($e in $entries) {
        if ($e -ieq $norm) {
            $removed = $true
            continue
        }
        [void]$kept.Add($e)
    }
    if ($removed) {
        Set-UserPathEntries $kept
        Write-Host "Removed from user PATH: $norm"
    } else {
        Write-Host "Not on user PATH (ok): $norm"
    }
    # Strip from this process even if User PATH was already clean.
    $proc = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($env:Path -split ';')) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($p.TrimEnd('\') -ieq $norm) { continue }
        [void]$proc.Add($p)
    }
    $env:Path = ($proc -join ';')
}

$cache = Get-CacheRoot
$latest = Join-Path $cache "latest"
$binLatest = Join-Path $latest "bin"
$ver = Get-PackVersion $ScriptRoot
$tag = Get-SanitizeTag $ver

$dest = $null
if ($tag -and (Test-Path -LiteralPath (Join-Path $cache $tag))) {
    $dest = Join-Path $cache $tag
} elseif ($ScriptRoot.StartsWith($cache, [System.StringComparison]::OrdinalIgnoreCase) -and ($ScriptRoot -ne $cache)) {
    $dest = $ScriptRoot
}

Write-Host "Uninstalling $PackId$(if ($ver) { " $ver" }) from $cache"

Remove-UserPathDir $binLatest
if ($dest) {
    Remove-UserPathDir (Join-Path $dest "bin")
}

$tc = [Environment]::GetEnvironmentVariable("RETCOMM_TOOLCHAIN_DIR", "User")
if ($tc -and (($tc -ieq $latest) -or ($dest -and ($tc -ieq $dest)))) {
    [Environment]::SetEnvironmentVariable("RETCOMM_TOOLCHAIN_DIR", $null, "User")
    Write-Host "Cleared user RETCOMM_TOOLCHAIN_DIR"
}
if ($env:RETCOMM_TOOLCHAIN_DIR -and (($env:RETCOMM_TOOLCHAIN_DIR -ieq $latest) -or ($dest -and ($env:RETCOMM_TOOLCHAIN_DIR -ieq $dest)))) {
    Remove-Item Env:RETCOMM_TOOLCHAIN_DIR -ErrorAction SilentlyContinue
}

if ($AllVersions) {
    if (Test-Path -LiteralPath $cache) {
        Remove-Item -LiteralPath $cache -Recurse -Force
        Write-Host "Removed cache tree $cache"
    }
} else {
    if (Test-Path -LiteralPath $latest) {
        Remove-Item -LiteralPath $latest -Recurse -Force
        Write-Host "Removed $latest"
    }
    if ($dest -and (Test-Path -LiteralPath $dest)) {
        Remove-Item -LiteralPath $dest -Recurse -Force
        Write-Host "Removed $dest"
    }
    if (Test-Path -LiteralPath $cache) {
        $left = @(Get-ChildItem -LiteralPath $cache -Force -ErrorAction SilentlyContinue)
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $cache -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host "$PackId PATH entries removed (idempotent if already clean)."
Write-Host "Open a new terminal for a fully clean environment."
