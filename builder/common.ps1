# builder/common.ps1 - Shared functions for Flutter Remote Builder (Windows)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$global:ProjectType = ""

# --- Refresh PATH from registry + common tool locations ---
# Called at load time and after each tool install
function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
    # Add common tool paths
    $extras = @(
        "$env:ProgramFiles\nodejs",
        "$env:ProgramFiles\Git\cmd",
        "$env:USERPROFILE\flutter\bin",
        "$env:LOCALAPPDATA\flutter\bin",
        "$env:ProgramFiles\Flutter\bin",
        "$env:USERPROFILE\fvm\default\bin",
        "$env:LOCALAPPDATA\Pub\Cache\bin",
        "$env:USERPROFILE\.pub-cache\bin",
        "$env:ProgramFiles\dart-sdk\bin"
    )

    # Always include the exact Gem bindir where fastlane gets installed
    $rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
    if ($rubyCmd) {
        $gemBin = try { ruby -e "print Gem.bindir" 2>$null } catch { $null }
        if ($gemBin -and (Test-Path $gemBin) -and ($env:PATH -notlike "*$gemBin*")) {
            $env:PATH += ";$gemBin"
        }
    }
}

# Refresh PATH immediately when common.ps1 is loaded
Refresh-Path

# --- Setup prerequisites on Windows ---
function Setup-Prerequisites {
    param([string]$Platform = "android")
    Write-Host "==> STEP: Setup prerequisites"

    # Winget check
    $hasWinget = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)
    $hasChoco  = $null -ne (Get-Command choco  -ErrorAction SilentlyContinue)

    # Java 17
    if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
        Write-Host "[INSTALL] Installing OpenJDK 17..."
        if ($hasWinget)       { winget install --id Microsoft.OpenJDK.17 -e --silent }
        elseif ($hasChoco)    { choco install openjdk17 -y }
        else { Write-Host "[WARN] Install Java 17 manually: https://adoptium.net" }
        Refresh-Path
    }
    # Ensure JAVA_HOME is set and valid
    if ($env:JAVA_HOME -and -not (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
        Write-Host "[WARN] Existing JAVA_HOME is invalid: $env:JAVA_HOME"
        $env:JAVA_HOME = $null
    }

    if (-not $env:JAVA_HOME) {
        $javaProps = cmd.exe /c "java -XshowSettings:properties -version 2>&1"
        foreach ($line in $javaProps) {
            if ($line -match 'java\.home\s*=\s*(.*)') {
                $env:JAVA_HOME = $matches[1].Trim()
                break
            }
        }
        if (-not $env:JAVA_HOME) {
            $javaCmd = Get-Command java -ErrorAction SilentlyContinue
            $javaExe = if ($javaCmd) { $javaCmd.Source } else { $null }
            if ($javaExe) {
                $env:JAVA_HOME = Split-Path (Split-Path $javaExe)
            }
        }
    }
    $javaVer = try { (java -version 2>&1) | Select-Object -First 1 } catch { "not found" }
    Write-Host "[OK] Java: $javaVer"

    # Flutter (only for Flutter projects)
    if ($global:ProjectType -eq "flutter") {
        if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
            Write-Host "[INSTALL] Installing Flutter..."
            if ($hasWinget)    { winget install --id Google.Flutter -e --silent }
            elseif ($hasChoco) { choco install flutter -y }
            else { Write-Host "[WARN] Install Flutter manually: https://flutter.dev" }
            Refresh-Path
        }
        $flutterVer = try { (flutter --version 2>&1) | Select-Object -First 1 } catch { "not found" }
        Write-Host "[OK] Flutter: $flutterVer"
    } else {
        Write-Host "[SKIP] Skipping Flutter (native project)"
    }

    # Ruby + Fastlane (required for Fastlane builds)
    if (-not (Get-Command ruby -ErrorAction SilentlyContinue)) {
        Write-Host "[INSTALL] Installing Ruby..."
        if ($hasWinget)    { winget install --id RubyInstallerTeam.RubyWithDevKit.3.2 -e --silent }
        elseif ($hasChoco) { choco install ruby -y }
        else { Write-Host "[WARN] Ruby not found. Fastlane will not work." }
        Refresh-Path
    }
    $rubyVer = try { (ruby --version 2>&1) | Select-Object -First 1 } catch { "not found" }
    Write-Host "[OK] Ruby: $rubyVer"

    if (Get-Command gem -ErrorAction SilentlyContinue) {
        if (-not (Get-Command fastlane -ErrorAction SilentlyContinue)) {
            Write-Host "[INSTALL] Installing Fastlane..."
            gem install fastlane --no-document
            if (-not (Get-Command fastlane -ErrorAction SilentlyContinue)) {
                $rubyBin = (Get-Command gem).Source | Split-Path
                if (Test-Path "$rubyBin\fastlane.bat") { $env:PATH += ";$rubyBin" }
            }
            Refresh-Path
        }
        $fastlaneVer = try { (fastlane --version 2>&1) | Select-Object -Last 1 } catch { "not found" }
        Write-Host "[OK] Fastlane: $fastlaneVer"
    } else {
        Write-Host "[WARN] gem not found, skipping Fastlane install"
    }

    # Android SDK
    if (-not $env:ANDROID_HOME) {
        $defaultSdk = "$env:LOCALAPPDATA\Android\Sdk"
        if (Test-Path $defaultSdk) {
            $env:ANDROID_HOME = $defaultSdk
        } else {
            Write-Host "[WARN] ANDROID_HOME not set. Install Android Studio or SDK Command-line Tools."
            Write-Host "    Default location: $defaultSdk"
        }
    }
    if ($env:ANDROID_HOME) {
        $env:PATH += ";$env:ANDROID_HOME\cmdline-tools\latest\bin;$env:ANDROID_HOME\platform-tools;$env:ANDROID_HOME\build-tools"
        Write-Host "[OK] Android SDK: $env:ANDROID_HOME"
        # Accept licenses
        $sdkManager = "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat"
        if (Test-Path $sdkManager) {
            "y" * 10 | & $sdkManager --licenses 2>$null
            & $sdkManager "platform-tools" 2>$null
        }
    }
}

# --- Git clone ---
function Clone-Repo {
    param([string]$RepoUrl, [string]$Branch, [string]$WorkDir)
    Write-Host "==> STEP: Git clone"
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    Set-Location $WorkDir
    if ($Branch) {
        Write-Host "Cloning branch: $Branch"
        git clone --branch $Branch $RepoUrl source_code
    } else {
        git clone $RepoUrl source_code
    }
    Set-Location source_code
}

# --- Load .env ---
function Load-Env {
    if (Test-Path ".env") {
        Write-Host "Loading .env from repository..."
        Get-Content ".env" | ForEach-Object {
            if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
                [System.Environment]::SetEnvironmentVariable($matches[1].Trim(), $matches[2].Trim(), "Process")
            }
        }
    }
}

# --- Detect project type ---
function Detect-ProjectType {
    if (Test-Path "pubspec.yaml") {
        $global:ProjectType = "flutter"
    } elseif ((Test-Path "build.gradle") -or (Test-Path "build.gradle.kts") -or
              (Test-Path "app\build.gradle") -or (Test-Path "app\build.gradle.kts")) {
        $global:ProjectType = "native_android"
    } else {
        $global:ProjectType = "flutter"  # default
    }
    Write-Host "[INFO] Detected project type: $($global:ProjectType)"
}

# --- Flutter pub get + code generation ---
function Flutter-Prepare {
    if ($global:ProjectType -ne "flutter") {
        Write-Host "==> SKIP: Flutter-Prepare (not a Flutter project)"
        return
    }
    Write-Host "==> STEP: flutter pub get"
    flutter pub get
    if (Select-String -Path "pubspec.yaml" -Pattern "build_runner" -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "==> STEP: build_runner"
        flutter pub run build_runner build --delete-conflicting-outputs
    }
    if (Test-Path "scripts\generate.dart") {
        Write-Host "==> STEP: scripts/generate.dart"
        dart run scripts\generate.dart
    }
}

# --- Auto-install required Android SDK from project ---
function Install-RequiredSdk {
    $sdkManager = "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat"
    if (-not (Test-Path $sdkManager)) { return }

    $gradleFiles = @("build.gradle","build.gradle.kts","app\build.gradle","app\build.gradle.kts",
                     "android\app\build.gradle","android\app\build.gradle.kts")
    $versions = @()
    foreach ($f in $gradleFiles) {
        if (Test-Path $f) {
            $versions += (Select-String -Path $f -Pattern 'compileSdk\w*\s*[=]?\s*(\d+)' |
                ForEach-Object { $_.Matches.Groups[1].Value })
        }
    }
    foreach ($ver in ($versions | Sort-Object -Unique)) {
        $platformDir = "$env:ANDROID_HOME\platforms\android-$ver"
        if (-not (Test-Path $platformDir)) {
            Write-Host "[INSTALL] Installing platforms;android-$ver..."
            & $sdkManager "platforms;android-$ver" 2>$null
        } else {
            Write-Host "[OK] platforms;android-$ver already installed"
        }
    }
}


# --- Optimize gradle.properties ---
function Optimize-Gradle {
    Write-Host "Optimizing gradle.properties..."
    $props = if ($global:ProjectType -eq "native_android") { "gradle.properties" } else { "android\gradle.properties" }
    if ($global:ProjectType -ne "native_android") {
        New-Item -ItemType Directory -Force -Path "android" | Out-Null
    }
    Add-Content $props "`norg.gradle.daemon=true"
    Add-Content $props "org.gradle.parallel=false"
    Add-Content $props "org.gradle.caching=false"
    Add-Content $props "org.gradle.workers.max=2"
    Add-Content $props "android.enableR8.fullMode=false"

    # Find aapt2
    if ($env:ANDROID_HOME -and (Test-Path "$env:ANDROID_HOME\build-tools")) {
        $aapt2 = Get-ChildItem "$env:ANDROID_HOME\build-tools" -Recurse -Filter "aapt2.exe" |
            Sort-Object FullName | Select-Object -Last 1
        if ($aapt2) {
            $aapt2Path = $aapt2.FullName -replace '\\', '/'
            Add-Content $props "android.aapt2FromMavenOverride=$aapt2Path"
            Write-Host "Using aapt2: $aapt2Path"
        }
    }
}

# --- Setup Fastfile ---
function Setup-Fastfile {
    param([string]$Platform = "android")
    $global:FastfilePath = ""
    $managed = $false

    $searchDir = $Platform
    if ($global:ProjectType -eq "native_android") { $searchDir = "." }

    if (Test-Path "$searchDir\fastlane\Fastfile") {
        $global:FastfilePath = "$searchDir\fastlane\Fastfile"
    } elseif (Test-Path "$searchDir\Fastfile") {
        $global:FastfilePath = "$searchDir\Fastfile"
    }

    if ($global:FastfilePath -and (Select-String -Path $global:FastfilePath -Pattern "Codex managed Fastfile" -Quiet -ErrorAction SilentlyContinue)) {
        $managed = $true
    }

    if (-not $global:FastfilePath -or $managed) {
        $targetDir = $Platform
        if ($global:ProjectType -eq "native_android") { $targetDir = "." }
        Write-Host "Generating default Fastlane config for $Platform ($($global:ProjectType))..."
        New-Item -ItemType Directory -Force -Path "$targetDir\fastlane" | Out-Null

        if ($Platform -eq "android" -and $global:ProjectType -eq "native_android") {
            @'
# Codex managed Fastfile - Native Android
default_platform(:android)

platform :android do
  desc "Build release APK (native Android)"
  lane :release do
    gradle(task: "assembleRelease")
  end

  desc "Build release AAB (native Android)"
  lane :bundle do
    gradle(task: "bundleRelease")
  end

  desc "Build debug APK (native Android)"
  lane :debug do
    gradle(task: "assembleDebug")
  end
end
'@ | Set-Content "$targetDir\fastlane\Fastfile" -Encoding UTF8
        } elseif ($Platform -eq "android") {
            @'
# Codex managed Fastfile - Flutter Android
default_platform(:android)

platform :android do
  desc "Build release APK"
  lane :release do
    sh("cd .. && flutter build apk --release")
  end

  desc "Build release AAB"
  lane :bundle do
    sh("cd .. && flutter build appbundle --release")
  end

  desc "Build debug APK"
  lane :debug do
    sh("cd .. && flutter build apk --debug")
  end
end
'@ | Set-Content "$targetDir\fastlane\Fastfile" -Encoding UTF8
        }
        $global:FastfilePath = "$targetDir\fastlane\Fastfile"
    }
}

# --- Run Fastlane ---
function Run-Fastlane {
    param([string]$Platform, [string]$Lane = "release")
    Write-Host "==> STEP: Fastlane"
    Write-Host "[RUN] Running Fastlane lane: $Lane for $Platform ($($global:ProjectType))..."

    $runDir = $Platform
    if ($global:ProjectType -eq "native_android") { $runDir = "." }

    Push-Location $runDir
    try {
        if ((Test-Path "Gemfile") -and (Get-Command bundle -ErrorAction SilentlyContinue)) {
            bundle install
            bundle exec fastlane $Lane
        } else {
            fastlane $Lane
        }
        if ($LASTEXITCODE -ne 0) { throw "Fastlane failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

# --- Build Android (default: Fastlane, fallback: direct) ---
function Build-Android {
    param([string]$Lane = "release")
    Write-Host "==> STEP: Build Android"

    # Default: always use Fastlane
    Setup-Fastfile -Platform "android"
    Run-Fastlane -Platform "android" -Lane $Lane
}

# --- Collect Android artifact ---
function Collect-AndroidArtifact {
    param([string]$OutputDir, [string]$Lane = "release")
    Write-Host "==> STEP: Collect artifact"
    $artifact = $null
    $isDebug = ($Lane -eq "debug")

    if ($global:ProjectType -eq "flutter") {
        $artifact = Get-ChildItem "build\app\outputs" -Recurse -Include "*.apk","*.aab" -ErrorAction SilentlyContinue |
            Where-Object {
                if ($isDebug) { $_.Name -match "debug" }
                else { $_.Name -notmatch "debug" }
            } | Select-Object -First 1
    } else {
        $artifact = Get-ChildItem "." -Recurse -Include "*.apk","*.aab" -ErrorAction SilentlyContinue |
            Where-Object {
                if ($_.FullName -notmatch "outputs") { $false }
                elseif ($isDebug) { $_.Name -match "debug" }
                else { $_.Name -notmatch "debug" }
            } | Select-Object -First 1
    }
    if ($artifact) {
        Copy-Item $artifact.FullName "$OutputDir\$($artifact.Name)" -Force
        $outputName = if ($isDebug) { "app-debug.apk" } else { "app-release.apk" }
        Copy-Item $artifact.FullName "$OutputDir\$outputName" -Force -ErrorAction SilentlyContinue
        Write-Host "Saved to $OutputDir\$($artifact.Name)"
    } else {
        Write-Host "Error: No build artifact found!"
        exit 1
    }
}

# --- Cleanup ---
function Cleanup-Temp {
    param([string]$Dir)
    if ($Dir -and (Test-Path $Dir)) {
        Remove-Item -Recurse -Force $Dir -ErrorAction SilentlyContinue
    }
}
