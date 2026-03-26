# builder/common.ps1 - Shared functions for Flutter Remote Builder (Windows)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$global:ProjectType = ""
$global:UseFvmFlutter = $false
$global:FlutterExe = $null

function Resolve-FlutterTool {
    $global:UseFvmFlutter = $false
    $global:FlutterExe = $null
    if ($global:ProjectType -ne "flutter") { return }
    if (Test-Path ".fvm\fvm_config.json") {
        if (Get-Command fvm -ErrorAction SilentlyContinue) {
            $global:UseFvmFlutter = $true
            Write-Host "[INFO] Flutter project uses FVM -- running via: fvm flutter"
            return
        }
        $fvmBin = Join-Path (Get-Location) ".fvm\flutter_sdk\bin\flutter.bat"
        if (Test-Path $fvmBin) {
            $global:FlutterExe = (Resolve-Path $fvmBin).Path
            Write-Host "[INFO] Flutter project uses FVM SDK at: $($global:FlutterExe)"
            return
        }
        Write-Host "[WARN] .fvm/fvm_config.json found but fvm is not in PATH and .fvm/flutter_sdk missing -- run 'fvm install' in the repo or install FVM."
    }
}

function Invoke-ProjectFlutter {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$FlutterArgs)
    if ($global:UseFvmFlutter) {
        & fvm flutter @FlutterArgs
        if ($LASTEXITCODE -ne 0) { throw "fvm flutter failed with exit code $LASTEXITCODE" }
    } elseif ($global:FlutterExe) {
        & $global:FlutterExe @FlutterArgs
        if ($LASTEXITCODE -ne 0) { throw "flutter failed with exit code $LASTEXITCODE" }
    } else {
        & flutter @FlutterArgs
        if ($LASTEXITCODE -ne 0) { throw "flutter failed with exit code $LASTEXITCODE" }
    }
}

function Invoke-ProjectDart {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$DartArgs)
    if ($global:UseFvmFlutter) {
        & fvm dart @DartArgs
        if ($LASTEXITCODE -ne 0) { throw "fvm dart failed with exit code $LASTEXITCODE" }
    } elseif ($global:FlutterExe) {
        $dartExe = Join-Path (Split-Path $global:FlutterExe) "dart.bat"
        if (Test-Path $dartExe) {
            & $dartExe @DartArgs
        } else {
            & dart @DartArgs
        }
        if ($LASTEXITCODE -ne 0) { throw "dart failed with exit code $LASTEXITCODE" }
    } else {
        & dart @DartArgs
        if ($LASTEXITCODE -ne 0) { throw "dart failed with exit code $LASTEXITCODE" }
    }
}

function Get-FlutterShCommand {
    if ($global:UseFvmFlutter) { return "fvm flutter" }
    if ($global:FlutterExe) {
        $p = ($global:FlutterExe -replace '\\', '/')
        return "`"$p`""
    }
    return "flutter"
}

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
    foreach ($p in $extras) {
        if ($p -and (Test-Path $p) -and ($env:PATH -notlike "*$p*")) {
            $env:PATH += ";$p"
        }
    }

    # Always include the exact Gem bindir where fastlane gets installed
    $rubyCmd = Get-Command ruby -ErrorAction SilentlyContinue
    if ($rubyCmd) {
        $gemBin = try { ruby -e "print Gem.bindir" 2>$null } catch { $null }
        if ($gemBin -and (Test-Path $gemBin) -and ($env:PATH -notlike "*$gemBin*")) {
            $env:PATH += ";$gemBin"
        }
    }
}

# --- Refresh PATH immediately when common.ps1 is loaded ---
Refresh-Path
$global:BuilderDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Setup prerequisites on Windows ---
function Setup-Prerequisites {
    param([string]$Platform = "android")
    Write-Host "==> STEP: Setup prerequisites"

    # Enable Developer Mode for symlink support (required by Flutter on Windows)
    $devModeKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
    $devModeVal = try { (Get-ItemProperty -Path $devModeKey -Name AllowDevelopmentWithoutDevLicense -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense } catch { 0 }
    if ($devModeVal -ne 1) {
        Write-Host "[INSTALL] Enabling Windows Developer Mode (required for Flutter symlinks)..."
        try {
            New-Item -Path $devModeKey -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $devModeKey -Name AllowDevelopmentWithoutDevLicense -Value 1 -Type DWord -Force
            Write-Host "[OK] Developer Mode enabled"
        } catch {
            Write-Host "[WARN] Could not enable Developer Mode (need Admin). Run server as Admin or enable manually: Settings > For Developers > Developer Mode"
        }
    } else {
        Write-Host "[OK] Developer Mode already enabled"
    }

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
        $usesFvm = Test-Path ".fvm\fvm_config.json"

        # Auto-install FVM if project uses it but fvm not found
        if ($usesFvm -and -not (Get-Command fvm -ErrorAction SilentlyContinue)) {
            Write-Host "[INSTALL] Project uses FVM but fvm not found. Installing FVM..."
            if (Get-Command dart -ErrorAction SilentlyContinue) {
                dart pub global activate fvm
            } elseif ($hasChoco) {
                choco install fvm -y
            } elseif ($hasWinget) {
                # Install Dart SDK first, then fvm
                winget install --id Google.DartSDK -e --silent
                Refresh-Path
                if (Get-Command dart -ErrorAction SilentlyContinue) {
                    dart pub global activate fvm
                }
            }
            Refresh-Path
        }

        # If FVM is available, run fvm install to get the correct Flutter version
        if ($usesFvm -and (Get-Command fvm -ErrorAction SilentlyContinue)) {
            if (-not (Test-Path ".fvm\flutter_sdk\bin\flutter.bat")) {
                Write-Host "[INSTALL] Running fvm install to get project's Flutter version..."
                fvm install --skip-pub-get
                Refresh-Path
            }
        }

        # Fallback: install Flutter directly if still not available
        $hasFlutter = (Get-Command fvm -ErrorAction SilentlyContinue) -or
                      (Test-Path ".fvm\flutter_sdk\bin\flutter.bat") -or
                      (Get-Command flutter -ErrorAction SilentlyContinue)
        if (-not $hasFlutter) {
            Write-Host "[INSTALL] Installing Flutter..."
            if ($hasWinget)    { winget install --id Google.Flutter -e --silent }
            elseif ($hasChoco) { choco install flutter -y }
            else { Write-Host "[WARN] Install Flutter manually: https://flutter.dev" }
            Refresh-Path
        }

        Resolve-FlutterTool
        $flutterVer = try {
            if ($global:UseFvmFlutter) { (fvm flutter --version 2>&1) | Select-Object -First 1 }
            elseif ($global:FlutterExe) { (& $global:FlutterExe --version 2>&1) | Select-Object -First 1 }
            else { (flutter --version 2>&1) | Select-Object -First 1 }
        } catch { "not found" }
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

    # Android SDK -- search common locations
    if (-not $env:ANDROID_HOME) {
        $sdkPaths = @(
            "$env:LOCALAPPDATA\Android\Sdk",
            "$env:USERPROFILE\AppData\Local\Android\Sdk",
            "$env:ProgramFiles\Android\Sdk",
            "${env:ProgramFiles(x86)}\Android\Sdk",
            "C:\Android\Sdk",
            "$env:USERPROFILE\Android\Sdk"
        )
        foreach ($p in $sdkPaths) {
            if ($p -and (Test-Path $p)) {
                $env:ANDROID_HOME = $p
                break
            }
        }
        if (-not $env:ANDROID_HOME) {
            # Auto-install Android SDK command-line tools
            Write-Host "[INSTALL] Android SDK not found. Installing command-line tools..."
            $sdkRoot = "$env:LOCALAPPDATA\Android\Sdk"
            New-Item -ItemType Directory -Force -Path "$sdkRoot\cmdline-tools" | Out-Null

            $cmdlineZip = "$env:TEMP\cmdline-tools.zip"
            $downloadUrl = "https://dl.google.com/android/repository/commandlinetools-win-11076708_latest.zip"
            Write-Host "[DOWNLOAD] Downloading Android command-line tools (~150MB). Please wait..."
            Write-Host "[DOWNLOAD] This may take several minutes depending on connection speed."
            $ProgressPreference = 'SilentlyContinue'
            $retries = 3
            for ($i = 1; $i -le $retries; $i++) {
                try {
                    Write-Host "[DOWNLOAD] Attempt $i/$retries..."
                    Invoke-WebRequest -Uri $downloadUrl -OutFile $cmdlineZip -UseBasicParsing -TimeoutSec 600
                    if (Test-Path $cmdlineZip) {
                        $sizeMB = [math]::Round((Get-Item $cmdlineZip).Length / 1MB, 1)
                        Write-Host "[DOWNLOAD] Complete: ${sizeMB}MB downloaded"
                    }
                    break
                } catch {
                    Write-Host "[WARN] Download attempt $i/$retries failed: $_"
                    if ($i -eq $retries) { throw "Failed to download Android SDK after $retries attempts" }
                    Start-Sleep -Seconds 5
                }
            }
            $ProgressPreference = 'Continue'

            Write-Host "[EXTRACT] Extracting..."
            Expand-Archive -Path $cmdlineZip -DestinationPath "$sdkRoot\cmdline-tools" -Force
            # Rename extracted folder to 'latest'
            if (Test-Path "$sdkRoot\cmdline-tools\cmdline-tools") {
                if (Test-Path "$sdkRoot\cmdline-tools\latest") {
                    Remove-Item -Recurse -Force "$sdkRoot\cmdline-tools\latest"
                }
                Rename-Item "$sdkRoot\cmdline-tools\cmdline-tools" "latest"
            }
            Remove-Item $cmdlineZip -Force -ErrorAction SilentlyContinue

            $env:ANDROID_HOME = $sdkRoot
            Write-Host "[OK] Android SDK installed at: $sdkRoot"
        }
    }
    # Also set ANDROID_SDK_ROOT for compatibility
    if ($env:ANDROID_HOME) {
        $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    }
    if ($env:ANDROID_HOME) {
        $env:PATH += ";$env:ANDROID_HOME\cmdline-tools\latest\bin;$env:ANDROID_HOME\platform-tools;$env:ANDROID_HOME\build-tools"
        Write-Host "[OK] Android SDK: $env:ANDROID_HOME"
        # Accept licenses (only if not yet accepted)
        $ld = "$env:ANDROID_HOME\licenses"
        if (-not (Test-Path "$ld\android-sdk-license")) {
            Write-Host "[INSTALL] Accepting SDK licenses..."
            New-Item -ItemType Directory -Force -Path $ld | Out-Null
            "`n24333f8a63b6825ea9c5514f83c2829b004d1fee" | Set-Content "$ld\android-sdk-license"
            "`n84831b9409646a918e30573bab4c9c91346d8abd" | Set-Content "$ld\android-sdk-preview-license"
            Write-Host "[OK] SDK licenses accepted"
        } else {
            Write-Host "[OK] SDK licenses already accepted"
        }
        # Install platform-tools only if missing
        if (-not (Test-Path "$env:ANDROID_HOME\platform-tools\adb.exe")) {
            $sdkManager = "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat"
            if (Test-Path $sdkManager) {
                Write-Host "[INSTALL] Installing platform-tools..."
                $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
                & $sdkManager "platform-tools" 2>&1 | Out-Null
                $ErrorActionPreference = $prevEAP
            }
        } else {
            Write-Host "[OK] platform-tools already installed"
        }
    }
}

# --- Git clone ---
function Clone-Repo {
    param([string]$RepoUrl, [string]$Branch, [string]$WorkDir)
    Write-Host "==> STEP: Git clone"
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    Set-Location $WorkDir
    # Clear old source if exists
    if (Test-Path "source_code") {
        Remove-Item -Recurse -Force "source_code" -ErrorAction SilentlyContinue
    }
    if ($Branch) {
        Write-Host "Cloning branch: $Branch"
        git clone -c core.longpaths=true --branch $Branch $RepoUrl source_code
    } else {
        git clone -c core.longpaths=true $RepoUrl source_code
    }
    Set-Location source_code
    # Init submodules if .gitmodules exists
    if (Test-Path ".gitmodules") {
        Write-Host "[INFO] Submodules detected, initializing..."
        git submodule update --init --recursive
        Write-Host "[OK] Submodules initialized"
    }
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
    Resolve-FlutterTool
    Write-Host "==> STEP: flutter pub get"
    Invoke-ProjectFlutter pub get
    if (Select-String -Path "pubspec.yaml" -Pattern "build_runner" -Quiet -ErrorAction SilentlyContinue) {
        Write-Host "==> STEP: build_runner"
        Invoke-ProjectDart run build_runner build --delete-conflicting-outputs
    }
    if (Test-Path "scripts\generate.dart") {
        Write-Host "==> STEP: scripts/generate.dart"
        Invoke-ProjectDart run scripts\generate.dart
    }
}

# --- Auto-install required Android SDK from project ---
function Install-RequiredSdk {
    $sdkManager = "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat"
    if (-not (Test-Path $sdkManager)) { return }

    # Only scan the main app's build.gradle — plugins/dependencies don't need separate platforms
    $gradleFiles = @("app\build.gradle","app\build.gradle.kts",
                     "android\app\build.gradle","android\app\build.gradle.kts")

    # Collect all required SDK versions and build-tools from gradle files
    $versions = @()
    $buildToolsVersions = @()
    foreach ($f in $gradleFiles) {
        if (Test-Path $f) {
            $versions += (Select-String -Path $f -Pattern 'compileSdk\w*\s*[=]?\s*(\d+)' |
                ForEach-Object { $_.Matches.Groups[1].Value })
            $buildToolsVersions += (Select-String -Path $f -Pattern 'buildToolsVersion\s*[=]?\s*["''](\d[\d.]+)' |
                ForEach-Object { $_.Matches.Groups[1].Value })
        }
    }

    # Check what's actually missing
    $missingPlatforms = @()
    foreach ($ver in ($versions | Sort-Object -Unique)) {
        if (-not (Test-Path "$env:ANDROID_HOME\platforms\android-$ver")) {
            $missingPlatforms += $ver
        } else {
            Write-Host "[OK] platforms;android-$ver already installed"
        }
    }

    $missingBuildTools = @()
    foreach ($btVer in ($buildToolsVersions | Sort-Object -Unique)) {
        if (-not (Test-Path "$env:ANDROID_HOME\build-tools\$btVer")) {
            $missingBuildTools += $btVer
        } else {
            Write-Host "[OK] build-tools;$btVer already installed"
        }
    }

    # Fallback: if project has no build-tools AND none installed at all
    $needFallbackBT = ($buildToolsVersions.Count -eq 0 -and -not (Test-Path "$env:ANDROID_HOME\build-tools\*"))

    # Nothing to install? Skip entirely
    if ($missingPlatforms.Count -eq 0 -and $missingBuildTools.Count -eq 0 -and -not $needFallbackBT) {
        Write-Host "[OK] All required SDK components already installed"
        return
    }

    # Accept licenses only when we need to install something
    $ld = "$env:ANDROID_HOME\licenses"
    if (-not (Test-Path "$ld\android-sdk-license")) {
        Write-Host "[INSTALL] Accepting SDK licenses..."
        $yesInput = ("y`n" * 30)
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        $yesInput | & $sdkManager --licenses 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP
    }

    # Install missing platforms
    foreach ($ver in $missingPlatforms) {
        Write-Host "[INSTALL] Installing platforms;android-$ver..."
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        & $sdkManager "platforms;android-$ver" 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP
    }

    # Install missing build-tools
    foreach ($btVer in $missingBuildTools) {
        Write-Host "[INSTALL] Installing build-tools;$btVer..."
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
        & $sdkManager "build-tools;$btVer" 2>&1 | Out-Null
        $ErrorActionPreference = $prevEAP
    }

    # Fallback: install default build-tools if none specified and none exist
    if ($needFallbackBT) {
        $latestVer = ($versions | Sort-Object -Unique | Select-Object -Last 1)
        if ($latestVer) {
            Write-Host "[INSTALL] No build-tools specified, installing build-tools;${latestVer}.0.0..."
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            & $sdkManager "build-tools;${latestVer}.0.0" 2>&1 | Out-Null
            $ErrorActionPreference = $prevEAP
        }
    }
}


# --- Optimize gradle.properties ---
function Optimize-Gradle {
    Write-Host "Optimizing gradle.properties..."
    # Optimize BOTH root and android/ gradle.properties
    $propsFiles = @()
    if (Test-Path "gradle.properties") { $propsFiles += "gradle.properties" }
    if ($global:ProjectType -ne "native_android") {
        New-Item -ItemType Directory -Force -Path "android" | Out-Null
        $propsFiles += "android\gradle.properties"
    }
    # Replace existing Gradle tuning keys in-place (only change values, keep everything else)
    $keysToReplace = @{
        "org.gradle.jvmargs" = $true
        "org.gradle.daemon" = $true
        "org.gradle.parallel" = $true
        "org.gradle.caching" = $true
        "org.gradle.workers.max" = $true
    }
    foreach ($pf in $propsFiles) {
        if (Test-Path $pf) {
            $lines = Get-Content $pf | Where-Object {
                $line = $_.Trim()
                $shouldRemove = $false
                foreach ($key in $keysToReplace.Keys) {
                    if ($line.StartsWith("$key=") -or $line.StartsWith("$key ")) {
                        $shouldRemove = $true
                        break
                    }
                }
                -not $shouldRemove
            }
            # Write without BOM using UTF8 no-BOM encoding
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllLines((Resolve-Path $pf).Path, $lines, $utf8NoBom)
        }
    }
    # Use last file as target for appending optimized values
    $props = if ($propsFiles.Count -gt 0) { $propsFiles[-1] } else { "gradle.properties" }

    # Find aapt2 -- fallback: install build-tools if missing
    $aapt2 = $null
    if ($env:ANDROID_HOME -and (Test-Path "$env:ANDROID_HOME\build-tools")) {
        $aapt2 = Get-ChildItem "$env:ANDROID_HOME\build-tools" -Recurse -Filter "aapt2.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName | Select-Object -Last 1
    }
    if (-not $aapt2) {
        $sdkMgr = "$env:ANDROID_HOME\cmdline-tools\latest\bin\sdkmanager.bat"
        if ($env:ANDROID_HOME -and (Test-Path $sdkMgr)) {
            Write-Host "[INSTALL] No aapt2 found. Installing latest build-tools..."
            $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
            $btList = & $sdkMgr --list 2>&1 | Select-String "build-tools;" | Select-Object -Last 1
            $ErrorActionPreference = $prevEAP
            if ($btList) {
                $btPkg = ($btList -split '\s+')[0].Trim()
                $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
                & $sdkMgr $btPkg 2>&1 | Out-Null
                $ErrorActionPreference = $prevEAP
                $aapt2 = Get-ChildItem "$env:ANDROID_HOME\build-tools" -Recurse -Filter "aapt2.exe" -ErrorAction SilentlyContinue |
                    Sort-Object FullName | Select-Object -Last 1
            }
        }
    }
    if ($aapt2) {
        $aapt2Path = $aapt2.FullName -replace '\\', '/'
        $existingProps = if (Test-Path $props) { Get-Content $props -Raw } else { "" }
        if ($existingProps -notmatch 'android\.aapt2FromMavenOverride') {
            Add-Content $props "android.aapt2FromMavenOverride=$aapt2Path"
        }
        Write-Host "Using aapt2: $aapt2Path"
    } else {
        Write-Host "[WARN] No aapt2 found. Build may fail."
    }

    # --- JVM / Gradle performance tuning ---
    # Kill stale Gradle daemons before build
    Write-Host "Killing stale Gradle daemons..."
    Get-Process java -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match 'gradle|GradleDaemon' } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $cpuCores = try { (Get-CimInstance Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum } catch { 4 }
    $totalMB = try { [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) } catch { 8192 }
    $availMB = try { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) } catch { 4096 }
    # Reserve 2GB for OS + Flutter/Dart, use the rest for Gradle heap
    $reserveMB = 2048
    $heapMB = [math]::Floor($availMB - $reserveMB)
    # Cap: min 1024MB, max 60% of total RAM or 8192MB (whichever is smaller)
    $heapCap = [math]::Min([math]::Floor($totalMB * 0.6), 8192)
    if ($heapMB -lt 1024) { $heapMB = 1024 }
    if ($heapMB -gt $heapCap) { $heapMB = $heapCap }
    $workersMax = 2
    Write-Host "[OK] Detected: ${cpuCores} cores, ${totalMB}MB total, ${availMB}MB free -> heap=${heapMB}m, workers=${workersMax}"

    # Ensure essential Android properties exist (add only if missing in ALL props files)
    $allPropsContent = ($propsFiles | Where-Object { Test-Path $_ } | ForEach-Object { Get-Content $_ }) -join "`n"
    if ($allPropsContent -notmatch 'android\.useAndroidX\s*=\s*true') {
        Add-Content $props "android.useAndroidX=true"
    }
    if ($allPropsContent -notmatch 'android\.nonTransitiveRClass\s*=\s*true') {
        Add-Content $props "android.nonTransitiveRClass=true"
    }
    Add-Content $props "org.gradle.daemon=false"
    Add-Content $props "org.gradle.jvmargs=-Xmx${heapMB}m -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+ExitOnOutOfMemoryError"
    Add-Content $props "org.gradle.parallel=true"
    Add-Content $props "org.gradle.caching=false"
    Add-Content $props "kotlin.compiler.execution.strategy=in-process"
    Add-Content $props "org.gradle.workers.max=$workersMax"

    # Update local.properties with sdk.dir (preserve existing keys, only update/add sdk.dir)
    if ($env:ANDROID_HOME) {
        $sdkPath = $env:ANDROID_HOME -replace '\\', '/'
        function Update-LocalProperties([string]$filePath) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            if (Test-Path $filePath) {
                $lines = Get-Content $filePath
                $found = $false
                $updated = $lines | ForEach-Object {
                    if ($_ -match '^sdk\.dir\s*=') { $found = $true; "sdk.dir=$sdkPath" }
                    else { $_ }
                }
                if (-not $found) { $updated += "sdk.dir=$sdkPath" }
                [System.IO.File]::WriteAllLines((Resolve-Path $filePath).Path, $updated, $utf8NoBom)
            } else {
                [System.IO.File]::WriteAllText($filePath, "sdk.dir=$sdkPath`n", $utf8NoBom)
            }
        }
        Update-LocalProperties "local.properties"
        if (Test-Path "android") {
            Update-LocalProperties "android\local.properties"
        }
        Write-Host "[OK] local.properties: sdk.dir=$sdkPath"
    }

    # --- Auto-inject common ProGuard/R8 dontwarn rules ---
    $proguardFiles = @(
        "proguard-rules.pro",
        "app\proguard-rules.pro",
        "android\app\proguard-rules.pro"
    )
    foreach ($pgFile in $proguardFiles) {
        if (Test-Path $pgFile) {
            $pgContent = Get-Content $pgFile -Raw -ErrorAction SilentlyContinue
            $dontwarnRules = @(
                "-dontwarn com.bytedance.sdk.openadsdk.**",
                "-dontwarn com.facebook.infer.annotation.**"
            )
            $added = $false
            foreach ($rule in $dontwarnRules) {
                if ($pgContent -notmatch [regex]::Escape($rule)) {
                    Add-Content $pgFile $rule
                    $added = $true
                }
            }
            if ($added) {
                Write-Host "[OK] Injected dontwarn rules into $pgFile"
            }
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
            $flavorCap = ""
            if ($global:Flavor) {
                $flavorCap = $global:Flavor.Substring(0,1).ToUpper() + $global:Flavor.Substring(1)
            }
            $fastfileContent = @(
                "# Codex managed Fastfile - Native Android",
                "default_platform(:android)",
                "",
                "platform :android do",
                "  desc `"Build release APK (native Android)`"",
                "  lane :release do",
                "    gradle(task: `"assemble${flavorCap}Release`", flags: `"--no-daemon`", print_command: true)",
                "  end",
                "",
                "  desc `"Build release AAB (native Android)`"",
                "  lane :bundle do",
                "    gradle(task: `"bundle${flavorCap}Release`", flags: `"--no-daemon`", print_command: true)",
                "  end",
                "end"
            ) -join "`n"
            $fastfileContent | Set-Content "$targetDir\fastlane\Fastfile" -Encoding UTF8
        } elseif ($Platform -eq "android") {
            $flavorFlag = ""
            if ($global:Flavor) { $flavorFlag = " --flavor $($global:Flavor)" }
            $fb = Get-FlutterShCommand
            $fastfileContent = @(
                "# Codex managed Fastfile - Flutter Android",
                "default_platform(:android)",
                "",
                "platform :android do",
                "  desc `"Build release APK`"",
                "  lane :release do",
                "    sh(`"cd .. && $fb build apk --release${flavorFlag}`")",
                "  end",
                "",
                "  desc `"Build release AAB`"",
                "  lane :bundle do",
                "    sh(`"cd .. && $fb build appbundle --release${flavorFlag}`")",
                "  end",
                "",
                "  desc `"Build debug APK`"",
                "  lane :debug do",
                "    sh(`"cd .. && $fb build apk --debug`")",
                "  end",
                "end"
            ) -join "`n"
            $fastfileContent | Set-Content "$targetDir\fastlane\Fastfile" -Encoding UTF8
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
        $env:CI = "true"
        $env:FASTLANE_DISABLE_COLORS = "true"

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

function Cleanup-OldBuilds {
    param([string]$BaseDir, [int]$AgeHours = 1)
    Write-Host "Cleaning old temp build folders..."
    if (-not (Test-Path $BaseDir)) { return }
    Get-ChildItem $BaseDir -Directory -Filter "flutter_build_*" -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-$AgeHours) } |
        ForEach-Object {
            Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "Removed: $($_.Name)"
        }
}
