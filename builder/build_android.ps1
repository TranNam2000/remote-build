# builder/build_android.ps1 - Android build script for Windows
param(
    [string]$RepoUrl,
    [string]$Branch = "",
    [string]$BuildId = "android_$(Get-Date -Format 'yyyyMMddHHmmss')",
    [string]$Lane = "release",
    [string]$Flavor = ""
)

$ErrorActionPreference = "Stop"
$BuilderDir = $PSScriptRoot
$WorkDir = "$env:TEMP\flutter_build_$BuildId"
$OutputDir = "$BuilderDir\completed_builds\$BuildId"

. "$PSScriptRoot\common.ps1"

Write-Host "Starting Android Build..."
Write-Host "Build ID: $BuildId"
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Clone -> detect project type -> setup
Clone-Repo -RepoUrl $RepoUrl -Branch $Branch -WorkDir $WorkDir
Detect-ProjectType
Setup-Prerequisites -Platform "android"
Load-Env
Install-RequiredSdk
Optimize-Gradle

if ($global:ProjectType -eq "flutter") {
    Flutter-Prepare
}

$global:Flavor = $Flavor
Write-Host "🎨 Flavor: $( if ($Flavor) { $Flavor } else { '(none)' } )"

# Build
$buildSuccess = $false
try {
    Build-Android -Lane $Lane
    $buildSuccess = $true
} catch {
    Write-Host "[WARN] First build attempt failed: $_"

    # Retry with compileSdk fix if needed
    $logContent = Get-Content "$env:TEMP\build_log_$BuildId.txt" -ErrorAction SilentlyContinue
    $requiredSdk = ($logContent | Select-String 'compile against version (\d+)' |
        ForEach-Object { [int]$_.Matches.Groups[1].Value } |
        Measure-Object -Maximum).Maximum

    if ($requiredSdk -gt 0) {
        Write-Host "[RETRY] Retrying with compileSdk = $requiredSdk..."
        Get-ChildItem -Recurse -Include "build.gradle","build.gradle.kts" | ForEach-Object {
            $c = Get-Content $_.FullName -Raw
            if ($c -match 'compileSdk\w*\s*[=]?\s*(\d+)') {
                $cur = [int]$Matches[1]
                if ($cur -lt $requiredSdk) {
                    Set-Content $_.FullName ($c -replace "compileSdk\w*(\s*[=]?\s*)$cur", "compileSdk`$1$requiredSdk") -NoNewline
                }
            }
        }
        try {
            Build-Android -Lane $Lane
            $buildSuccess = $true
        } catch {
            Write-Host "[ERROR] Retry also failed: $_"
        }
    }
}

# Check if artifact exists regardless of exit code (Fastlane may exit non-zero even on success)
$ErrorActionPreference = "SilentlyContinue"
$hasArtifact = $false
if ($global:ProjectType -eq "flutter") {
    $hasArtifact = [bool](Get-ChildItem "build\app\outputs" -Recurse -Include "*.apk","*.aab" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "debug" } | Select-Object -First 1)
} else {
    $hasArtifact = [bool](Get-ChildItem "." -Recurse -Include "*.apk","*.aab" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "outputs" -and $_.Name -notmatch "debug" } | Select-Object -First 1)
}
$ErrorActionPreference = "Stop"

if ($hasArtifact) {
    if (-not $buildSuccess) {
        Write-Host '[INFO] Fastlane exited with error but artifact was found - treating as success'
    }
    Collect-AndroidArtifact -OutputDir $OutputDir -Lane $Lane
    Write-Host '[OK] Done!'
} else {
    Write-Host '[ERROR] No build artifact found after all attempts'
    exit 1
}
