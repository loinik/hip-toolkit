<#
.SYNOPSIS
    Builds all four Windows release packages for HIP Toolkit.

.DESCRIPTION
    Produces:
      dist/HIP.Toolkit-<ver>-windows-x64-portable.zip
      dist/HIP.Toolkit-<ver>-windows-x64-self-contained.zip
      dist/HIP.Toolkit-<ver>-windows-arm64-portable.zip
      dist/HIP.Toolkit-<ver>-windows-arm64-self-contained.zip

    "Portable"       - WinAppSDK bundled, requires .NET 8 Desktop Runtime on the host.
    "Self-contained" - WinAppSDK + .NET 8 runtime all bundled, no dependencies.

.PARAMETER Configuration
    Release (default) or Debug.

.EXAMPLE
    .\scripts\build-windows.ps1
    .\scripts\build-windows.ps1 -Configuration Debug
#>

param(
    [string]$Configuration = "Release"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Paths ---

$RepoRoot    = Split-Path $PSScriptRoot -Parent
$SolutionDir = $RepoRoot
$CsprojFile  = Join-Path $RepoRoot "Sources\App\Windows\HIP Toolkit.csproj"
$CoreVcxproj = Join-Path $RepoRoot "Sources\Platform\Windows\HIP.Core.vcxproj"
$BridgeVcxproj = Join-Path $RepoRoot "Sources\Platform\Windows\HIP.Bridge.vcxproj"
$DistDir     = Join-Path $RepoRoot "dist"
$Version     = (Get-Content (Join-Path $RepoRoot "VERSION")).Trim()

New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

# --- Locate MSBuild ---

function Find-MSBuild {
    # Try vswhere first (most reliable on developer machines)
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe 2>$null | Select-Object -First 1
        if ($vsPath -and (Test-Path $vsPath)) { return $vsPath }
    }
    # Fall back to PATH
    $msbuild = Get-Command msbuild -ErrorAction SilentlyContinue
    if ($msbuild) { return $msbuild.Source }
    throw "MSBuild not found. Install Visual Studio 2022 with 'Desktop development with C++'."
}

$MSBuild = Find-MSBuild
Write-Host "  MSBuild : $MSBuild" -ForegroundColor DarkGray

# --- Helper ---

function Invoke-Step([string]$Label, [scriptblock]$Body) {
    Write-Host ""
    Write-Host "--- $Label" -ForegroundColor Cyan
    & $Body
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw "Step failed: $Label (exit $LASTEXITCODE)" }
}

function Build-NativeCpp([string]$Arch) {
    # SolutionDir MUST be passed explicitly. The vcxproj OutDir is
    # "$(SolutionDir)build\$(Platform)\$(Configuration)\$(ProjectName)\". When a
    # .vcxproj is built directly (not via the .sln), MSBuild defaults SolutionDir
    # to the project's own folder, so output lands in Sources\Platform\Windows\build.
    # But the C# csproj looks for HIP.Bridge.dll under "$(SolutionDir)build\..." with
    # SolutionDir = repo root. Pin both to the repo root so the paths line up.
    Invoke-Step "C++ HIP.Core  [$Arch $Configuration]" {
        & $MSBuild $CoreVcxproj /p:Configuration=$Configuration /p:Platform=$Arch /p:SolutionDir="$SolutionDir\" /nologo /v:minimal /m
    }
    Invoke-Step "C++ HIP.Bridge [$Arch $Configuration]" {
        & $MSBuild $BridgeVcxproj /p:Configuration=$Configuration /p:Platform=$Arch /p:SolutionDir="$SolutionDir\" /nologo /v:minimal /m
    }
}

function Publish-App([string]$Arch, [string]$RID, [bool]$SelfContained, [string]$OutZip) {
    $TmpDir = Join-Path $DistDir "_tmp_${Arch}_$(if ($SelfContained) {'sc'} else {'portable'})"
    if (Test-Path $TmpDir) { Remove-Item $TmpDir -Recurse -Force }

    $scFlag = if ($SelfContained) { "true" } else { "false" }
    $label  = if ($SelfContained) { "self-contained" } else { "portable" }

    # Publish with the *Visual Studio* MSBuild, not `dotnet publish`. The .NET SDK
    # MSBuild cannot load WindowsAppSDK's ExpandPriContent task (MSB4062: the
    # Microsoft.Build.Packaging.Pri.Tasks.dll only ships with VS), so PRI/resource
    # generation fails. VS MSBuild has that task. Use forward slashes in PublishDir
    # to avoid PowerShell's trailing-backslash quoting trap when calling a native exe.
    $pubDir = ($TmpDir -replace '\\','/') + '/'

    Invoke-Step "publish [$Arch / $label]" {
        & $MSBuild $CsprojFile `
            /restore `
            /t:Publish `
            /p:Configuration=$Configuration `
            /p:Platform=$Arch `
            /p:RuntimeIdentifier=$RID `
            /p:SelfContained=$scFlag `
            /p:PublishDir=$pubDir `
            /p:SolutionDir="$SolutionDir\" `
            /nologo /v:minimal /m
    }

    # For portable builds: add a small runtime README
    if (-not $SelfContained) {
        $readme = @"
HIP Toolkit $Version - Portable ($RID)

This build requires the .NET 8 Desktop Runtime to be installed:
  https://dotnet.microsoft.com/en-us/download/dotnet/8.0

The Windows App SDK runtime is already bundled - no separate install needed.
"@
        $readme | Set-Content (Join-Path $TmpDir "RUNTIME-REQUIRED.txt") -Encoding UTF8
    }

    Invoke-Step "ZIP -> $OutZip" {
        if (Test-Path $OutZip) { Remove-Item $OutZip -Force }
        Compress-Archive -Path "$TmpDir\*" -DestinationPath $OutZip -CompressionLevel Optimal
        $size = [math]::Round((Get-Item $OutZip).Length / 1MB, 1)
        Write-Host "  $([System.IO.Path]::GetFileName($OutZip))  ($size MB)" -ForegroundColor Green
    }

    Remove-Item $TmpDir -Recurse -Force
}

# --- Main ---

Write-Host ""
Write-Host "HIP Toolkit $Version - Windows release build" -ForegroundColor White
Write-Host "Configuration : $Configuration" -ForegroundColor DarkGray

foreach ($arch in @("x64", "ARM64")) {
    $rid = if ($arch -eq "x64") { "win-x64" } else { "win-arm64" }

    Build-NativeCpp -Arch $arch

    Publish-App -Arch $arch -RID $rid -SelfContained $false `
        -OutZip (Join-Path $DistDir "HIP.Toolkit-$Version-windows-$rid-portable.zip")

    Publish-App -Arch $arch -RID $rid -SelfContained $true `
        -OutZip (Join-Path $DistDir "HIP.Toolkit-$Version-windows-$rid-self-contained.zip")
}

Write-Host ""
Write-Host "All packages written to: $DistDir" -ForegroundColor Green
Write-Host ""
Get-ChildItem $DistDir -Filter "HIP.Toolkit-$Version-windows-*.zip" |
    ForEach-Object { Write-Host "  $($_.Name)  ($([math]::Round($_.Length/1MB,1)) MB)" }
Write-Host ""
