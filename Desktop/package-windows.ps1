#Requires -Version 5.1
<#
.SYNOPSIS
  Package ExtendCast Windows Release (portable folder and optional NSIS installer).

.DESCRIPTION
  Always bundles:
    - Qt runtime via windeployqt
    - FFmpeg / app DLLs from the Release build output
    - MSVC CRT DLLs next to ExtendCast.exe (VCRUNTIME140.dll, MSVCP140.dll, ...)
    - vc_redist.x64.exe (installer runs it quietly; also usable standalone)

  Missing VC runtime is a hard error — do not ship without it.

.EXAMPLE
  .\package-windows.ps1 -BuildDir D:\Temp\ExtendCast\windows-build -OutDir D:\ExtendCast\Windows-x64 -Installer
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir,

    [Parameter(Mandatory = $true)]
    [string]$OutDir,

    [string]$QtBin = '',

    [string]$DesktopDir = '',

    [switch]$Installer,

    [string]$InstallerOut = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-DesktopDir {
    param([string]$Hint)
    if ($Hint -and (Test-Path (Join-Path $Hint 'installer.nsi'))) {
        return (Resolve-Path $Hint).Path
    }
    $here = $PSScriptRoot
    if (Test-Path (Join-Path $here 'installer.nsi')) {
        return $here
    }
    throw "DesktopDir not found (expected installer.nsi next to package-windows.ps1)"
}

function Find-WindeployQt {
    param([string]$Hint)
    if ($Hint) {
        $candidate = Join-Path $Hint 'windeployqt.exe'
        if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
        if ((Split-Path $Hint -Leaf) -eq 'windeployqt.exe' -and (Test-Path $Hint)) {
            return (Resolve-Path $Hint).Path
        }
    }
    $fromPath = Get-Command windeployqt.exe -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    foreach ($root in @('C:\Qt', 'D:\Qt')) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem $root -Recurse -Filter windeployqt.exe -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'msvc' } |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    throw "windeployqt.exe not found. Pass -QtBin <Qt>/bin or add it to PATH."
}

function Find-VcRedistLayout {
    # Returns @{ RedistExe = '...vc_redist.x64.exe'; CrtDir = '...\\x64\\Microsoft.VC*.CRT' }
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:VCToolsRedistDir -and (Test-Path $env:VCToolsRedistDir)) {
        $candidates.Add($env:VCToolsRedistDir)
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) {
        $installPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if ($installPath) {
            $redistRoot = Join-Path $installPath 'VC\Redist\MSVC'
            if (Test-Path $redistRoot) { $candidates.Add($redistRoot) }
        }
    }

    foreach ($edition in @('Enterprise', 'Professional', 'Community', 'BuildTools')) {
        $p = "C:\Program Files\Microsoft Visual Studio\2022\$edition\VC\Redist\MSVC"
        if (Test-Path $p) { $candidates.Add($p) }
    }

    foreach ($root in $candidates) {
        $redistExe = Get-ChildItem $root -Recurse -Filter 'vc_redist.x64.exe' -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if (-not $redistExe) { continue }

        $crtDir = Get-ChildItem $root -Recurse -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '\\x64\\Microsoft\.VC\d+\.CRT$' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if (-not $crtDir) { continue }

        $vcruntime = Join-Path $crtDir.FullName 'vcruntime140.dll'
        if (-not (Test-Path $vcruntime)) { continue }

        return @{
            RedistExe = $redistExe.FullName
            CrtDir    = $crtDir.FullName
        }
    }

    throw @"
Visual C++ redistributable not found.
Install VS 2022 C++ Desktop workload, or ensure vc_redist.x64.exe and
Microsoft.VC*.CRT (with vcruntime140.dll) are available under VC\Redist\MSVC.
"@
}

$desktop = Resolve-DesktopDir -Hint $DesktopDir
$buildDir = (Resolve-Path $BuildDir).Path
$exeSrc = Join-Path $buildDir 'Release\ExtendCast.exe'
if (-not (Test-Path $exeSrc)) {
    throw "Release binary not found: $exeSrc (build Release first)"
}

$versionFile = Join-Path $desktop 'VERSION'
$version = (Get-Content $versionFile -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Desktop/VERSION must be semantic X.Y.Z, got '$version'"
}

$windeployqt = Find-WindeployQt -Hint $QtBin
$vc = Find-VcRedistLayout

Write-Host "Desktop:     $desktop"
Write-Host "BuildDir:    $buildDir"
Write-Host "OutDir:      $OutDir"
Write-Host "Version:     $version"
Write-Host "windeployqt: $windeployqt"
Write-Host "VC redist:   $($vc.RedistExe)"
Write-Host "VC CRT:      $($vc.CrtDir)"

if (Test-Path $OutDir) {
    Remove-Item $OutDir -Recurse -Force
}
New-Item -ItemType Directory -Force $OutDir | Out-Null

Copy-Item $exeSrc $OutDir

& $windeployqt --release --no-translations --no-system-d3d-compiler --no-opengl-sw `
    (Join-Path $OutDir 'ExtendCast.exe')
if ($LASTEXITCODE -ne 0) {
    throw "windeployqt failed with exit code $LASTEXITCODE"
}

Get-ChildItem (Join-Path $buildDir 'Release\*.dll') -ErrorAction SilentlyContinue |
    ForEach-Object { Copy-Item $_.FullName $OutDir -Force }

# Qt multimedia may pull an unrelated FFmpeg set; receiver uses its own vcpkg build.
@(
    'multimedia\ffmpegmediaplugin.dll',
    'avcodec-60.dll',
    'avformat-60.dll',
    'avutil-58.dll',
    'swresample-4.dll',
    'swscale-7.dll'
) | ForEach-Object {
    Remove-Item (Join-Path $OutDir $_) -Force -ErrorAction SilentlyContinue
}

Copy-Item (Join-Path $desktop 'appicon.ico') $OutDir -ErrorAction SilentlyContinue

# Required: ship CRT next to exe so machines without system VC++ redist still start.
Copy-Item (Join-Path $vc.CrtDir '*') $OutDir -Force
Copy-Item $vc.RedistExe (Join-Path $OutDir 'vc_redist.x64.exe') -Force

$required = @(
    'ExtendCast.exe',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'msvcp140.dll',
    'vc_redist.x64.exe'
)
foreach ($name in $required) {
    $path = Join-Path $OutDir $name
    if (-not (Test-Path $path)) {
        throw "Packaging incomplete: missing $name in $OutDir"
    }
}

Write-Host "Portable package ready: $OutDir"

if (-not $Installer) {
    return
}

$makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
if (-not $makensis) {
    $nsisCandidates = @(
        'C:\Program Files (x86)\NSIS\makensis.exe',
        'C:\Program Files\NSIS\makensis.exe'
    )
    foreach ($c in $nsisCandidates) {
        if (Test-Path $c) {
            $makensis = Get-Item $c
            break
        }
    }
}
if (-not $makensis) {
    throw "makensis.exe not found. Install NSIS or add it to PATH."
}

# NSIS consumes the completed portable directory directly. Keeping this source
# path configurable avoids copying a second staging tree into the repository,
# which is especially important for local release builds whose binaries belong
# on a dedicated output drive. SOURCE_DIR and OUTPUT_FILE are passed as absolute
# paths so CI, developer workstations, and mapped workspaces all follow the same
# packaging path. installer.nsi still provides backward-compatible defaults for
# direct/manual makensis invocations. The portable directory is fully validated
# above before NSIS sees it, so the installer cannot silently package a partial
# runtime. makensis writes directly to InstallerOut; there is no temporary setup
# executable to discover, copy, or remove from the source tree afterward.
$sourceDir = (Resolve-Path $OutDir).Path
if (-not $InstallerOut) {
    $InstallerOut = Join-Path (Split-Path $sourceDir -Parent) "ExtendCast-Setup-$version.exe"
}
$installerDir = Split-Path $InstallerOut -Parent
if ($installerDir) {
    New-Item -ItemType Directory -Force $installerDir | Out-Null
}
$InstallerOut = [System.IO.Path]::GetFullPath($InstallerOut)

Push-Location $desktop
try {
    $makensisPath = if ($makensis -is [System.Management.Automation.CommandInfo]) {
        $makensis.Source
    } else {
        $makensis.FullName
    }
    & $makensisPath /INPUTCHARSET UTF8 `
        "/DPRODUCT_VERSION=$version" `
        "/DSOURCE_DIR=$sourceDir" `
        "/DOUTPUT_FILE=$InstallerOut" `
        installer.nsi
    if ($LASTEXITCODE -ne 0) {
        throw "makensis failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path $InstallerOut)) {
        throw "Installer not produced: $InstallerOut"
    }
}
finally {
    Pop-Location
}

Write-Host "Installer ready: $InstallerOut"
Get-Item $InstallerOut | Format-List FullName, Length, LastWriteTime
