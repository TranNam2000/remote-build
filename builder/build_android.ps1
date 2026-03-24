# builder/build_android.ps1 - Android build script for Windows
param(
    [string]$RepoUrl,
    [string]$Branch = "",
    [string]$BuildId = "android_$(Get-Date -Format 'yyyyMMddHHmmss')",
    [string]$Lane = "release"
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

# Build
try {
    Build-Android -Lane $Lane
} catch {
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
        Build-Android -Lane $Lane
    } else {
        Write-Host "[ERROR] Build failed: $_"
        exit 1
    }
}

Collect-AndroidArtifact -OutputDir $OutputDir -Lane $Lane
Cleanup-Temp -Dir $WorkDir
Write-Host "[OK] Done!"
