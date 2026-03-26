@echo off
setlocal enabledelayedexpansion

set REPO_URL=%~1
set BRANCH=%~2
set BUILD_ID=%~3
if "%BUILD_ID%"=="" (
    for /f "tokens=2 delims==" %%I in ('wmic os get localdatetime /value') do set "datetime=%%I"
    set "BUILD_ID=android_!datetime:~0,14!"
)
set LANE=%~4
if "%LANE%"=="" set "LANE=release"

set "BUILDER_DIR=%~dp0"
set "WORK_DIR=%TEMP%\flutter_build_%BUILD_ID%"
set "OUTPUT_DIR=%BUILDER_DIR%completed_builds\%BUILD_ID%"

echo ============================================
echo   Android Build - Windows
echo   Build ID: %BUILD_ID%
echo ============================================

if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"

:: ====== Prerequisites ======
echo ==^> STEP: Check prerequisites

:: Chocolatey
where choco >nul 2>&1
if errorlevel 1 (
    echo [!] Chocolatey not found. Installing...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    set "PATH=%ALLUSERSPROFILE%\chocolatey\bin;%PATH%"
)

:: Git
where git >nul 2>&1
if errorlevel 1 (
    echo [!] Installing Git...
    choco install git -y
    set "PATH=C:\Program Files\Git\bin;%PATH%"
)

:: Java 17
where java >nul 2>&1
if errorlevel 1 (
    echo [!] Installing OpenJDK 17...
    choco install temurin17 -y
)
if not defined JAVA_HOME (
    for /d %%D in ("C:\Program Files\Eclipse Adoptium\jdk-17*") do set "JAVA_HOME=%%D"
    if not defined JAVA_HOME (
        for /d %%D in ("C:\Program Files\Java\jdk-17*") do set "JAVA_HOME=%%D"
    )
    if defined JAVA_HOME set "PATH=!JAVA_HOME!\bin;%PATH%"
)
echo [OK] Java: & java -version 2>&1 | findstr /i "version"

:: Flutter
where flutter >nul 2>&1
if errorlevel 1 (
    echo [!] Installing Flutter...
    choco install flutter -y
    set "PATH=C:\tools\flutter\bin;%PATH%"
)
echo [OK] Flutter: & flutter --version 2>&1 | findstr /i "Flutter"

:: Android SDK
if not defined ANDROID_HOME (
    if exist "%LOCALAPPDATA%\Android\Sdk" (
        set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
    ) else if exist "%USERPROFILE%\AppData\Local\Android\Sdk" (
        set "ANDROID_HOME=%USERPROFILE%\AppData\Local\Android\Sdk"
    )
)
if defined ANDROID_HOME (
    set "PATH=%PATH%;!ANDROID_HOME!\cmdline-tools\latest\bin;!ANDROID_HOME!\platform-tools"
    echo [OK] Android SDK: !ANDROID_HOME!
) else (
    echo [!] Android SDK not found. Please install Android Studio or set ANDROID_HOME.
)

:: Ruby + Fastlane
where ruby >nul 2>&1
if errorlevel 1 (
    echo [!] Installing Ruby...
    choco install ruby -y
    set "PATH=C:\tools\ruby33\bin;%PATH%"
)
where fastlane >nul 2>&1
if errorlevel 1 (
    echo [!] Installing Fastlane...
    gem install fastlane --no-document
)
echo [OK] Fastlane

:: ====== Clone ======
echo ==^> STEP: Git clone
if not exist "%WORK_DIR%" mkdir "%WORK_DIR%"
cd /d "%WORK_DIR%"
if not "%BRANCH%"=="" (
    git clone --branch "%BRANCH%" "%REPO_URL%" source_code
) else (
    git clone "%REPO_URL%" source_code
)
cd source_code

:: ====== Detect project type ======
echo ==^> STEP: Detect project type
set "PROJECT_TYPE=flutter"
if exist "pubspec.yaml" (
    set "PROJECT_TYPE=flutter"
    echo [OK] Detected: Flutter project
) else if exist "build.gradle" (
    set "PROJECT_TYPE=native_android"
    echo [OK] Detected: Native Android project
) else if exist "build.gradle.kts" (
    set "PROJECT_TYPE=native_android"
    echo [OK] Detected: Native Android project
) else if exist "app\build.gradle" (
    set "PROJECT_TYPE=native_android"
    echo [OK] Detected: Native Android project
) else if exist "app\build.gradle.kts" (
    set "PROJECT_TYPE=native_android"
    echo [OK] Detected: Native Android project
)

:: ====== Setup prerequisites based on project type ======
if "%PROJECT_TYPE%"=="flutter" (
    echo ==^> STEP: Setup Flutter environment
) else (
    echo ==^> STEP: Setup Native Android environment
)

:: ====== Load .env ======
if exist ".env" (
    echo Loading .env...
    for /f "usebackq tokens=1,* delims==" %%A in (".env") do (
        set "%%A=%%B"
    )
)

:: ====== Optimize Gradle ======
echo ==^> STEP: Optimize Gradle
if "%PROJECT_TYPE%"=="native_android" (
    set "PROPS=gradle.properties"
) else (
    if not exist "android" mkdir android
    set "PROPS=android\gradle.properties"
)

:: Find aapt2
set "AAPT2_PATH="
if defined ANDROID_HOME (
    for /f "delims=" %%F in ('dir /b /s "%ANDROID_HOME%\build-tools\aapt2.exe" 2^>nul') do set "AAPT2_PATH=%%F"
)
if defined AAPT2_PATH (
    echo Using aapt2: !AAPT2_PATH!
    echo android.aapt2FromMavenOverride=!AAPT2_PATH!>> "!PROPS!"
)

:: Kill stale Gradle daemons aggressively
echo Killing stale Gradle daemons...
taskkill /f /im java.exe /fi "WINDOWTITLE eq *GradleDaemon*" >nul 2>&1
taskkill /f /im java.exe /fi "COMMANDLINE eq *gradle*" >nul 2>&1
timeout /t 2 >nul

echo org.gradle.daemon=true>> "!PROPS!"
:: Detect RAM and allocate conservatively (40%% max, min 2GB, cap 6GB)
set "JVM_MAX=2048"
for /f "tokens=2 delims==" %%M in ('wmic computersystem get TotalPhysicalMemory /value 2^>nul') do (
    set /a "TOTAL_MB=%%M / 1048576" 2>nul
    set /a "AVAILABLE_MB=!TOTAL_MB! - 1024" 2>nul
    if !AVAILABLE_MB! LSS 2048 set "AVAILABLE_MB=2048"
    set /a "HEAP_MB=!AVAILABLE_MB! * 40 / 100" 2>nul
    if !HEAP_MB! LSS 2048 set "HEAP_MB=2048"
    if !HEAP_MB! GTR 6144 set "HEAP_MB=6144"
    set "JVM_MAX=!HEAP_MB!"
)
echo JVM heap: !JVM_MAX!m ^(total RAM: !TOTAL_MB!MB^)
echo org.gradle.jvmargs=-Xmx!JVM_MAX!m -XX:MaxMetaspaceSize=512m -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -XX:+HeapDumpOnOutOfMemoryError>> "!PROPS!"
echo org.gradle.parallel=false>> "!PROPS!"
echo org.gradle.caching=false>> "!PROPS!"
echo org.gradle.workers.max=2>> "!PROPS!"
echo android.dexOptions.incremental=true>> "!PROPS!"

:: ====== Auto-inject ProGuard dontwarn rules ======
set "PG_FILES=proguard-rules.pro app\proguard-rules.pro android\app\proguard-rules.pro"
for %%P in (%PG_FILES%) do (
    if exist "%%P" (
        findstr /c:"dontwarn com.bytedance" "%%P" >nul 2>&1
        if errorlevel 1 (
            echo -dontwarn com.bytedance.sdk.openadsdk.**>>"%%P"
            echo -dontwarn com.facebook.infer.annotation.**>>"%%P"
            echo [OK] Injected dontwarn rules into %%P
        )
    )
)

:: ====== Conditional: Flutter only ======
if "%PROJECT_TYPE%"=="flutter" (
    echo ==^> STEP: Flutter pub get
    call flutter pub get

    findstr /i "build_runner" pubspec.yaml >nul 2>&1
    if not errorlevel 1 (
        echo ==^> STEP: Build runner
        call flutter pub run build_runner build --delete-conflicting-outputs
    )

    if exist "scripts\generate.dart" (
        echo ==^> STEP: Scripts generate
        call dart run scripts\generate.dart
    )
) else (
    echo [i] Skipping Flutter steps ^(native Android project^)
)

:: ====== Setup Fastfile ======
echo ==^> STEP: Setup Fastlane
if "%PROJECT_TYPE%"=="native_android" (
    set "FL_DIR=fastlane"
) else (
    set "FL_DIR=android\fastlane"
)

:: Use existing Fastfile if present and not managed by us
set "NEED_GENERATE=1"
if exist "!FL_DIR!\Fastfile" (
    findstr /i "Codex managed" "!FL_DIR!\Fastfile" >nul 2>&1
    if errorlevel 1 set "NEED_GENERATE=0"
)

if "!NEED_GENERATE!"=="1" (
    if not exist "!FL_DIR!" mkdir "!FL_DIR!"
    if "%PROJECT_TYPE%"=="native_android" (
        echo Generating Fastfile for native Android...
        (
            echo # Codex managed Fastfile - Native Android
            echo default_platform^(:android^)
            echo.
            echo platform :android do
            echo   desc "Build release APK"
            echo   lane :release do
            echo     gradle^(task: "assembleRelease"^)
            echo   end
            echo.
            echo   desc "Build release AAB"
            echo   lane :bundle do
            echo     gradle^(task: "bundleRelease"^)
            echo   end
            echo end
        ) > "!FL_DIR!\Fastfile"
    ) else (
        echo Generating Fastfile for Flutter Android...
        (
            echo # Codex managed Fastfile - Flutter Android
            echo default_platform^(:android^)
            echo.
            echo platform :android do
            echo   desc "Build release APK"
            echo   lane :release do
            echo     sh^("cd .. ^&^& flutter build apk --release"^)
            echo   end
            echo.
            echo   desc "Build release AAB"
            echo   lane :bundle do
            echo     sh^("cd .. ^&^& flutter build appbundle --release"^)
            echo   end
            echo end
        ) > "!FL_DIR!\Fastfile"
    )
)

:: ====== Run Fastlane ======
echo ==^> STEP: Fastlane %LANE%
if "%PROJECT_TYPE%"=="native_android" (
    call fastlane %LANE%
) else (
    cd android
    call fastlane %LANE%
    cd ..
)

:: ====== Collect artifact ======
echo ==^> STEP: Collect artifact
set "ARTIFACT="
if "%PROJECT_TYPE%"=="native_android" (
    for /r %%F in (*.apk *.aab) do (
        echo %%F | findstr /i "debug" >nul 2>&1
        if errorlevel 1 (
            if not defined ARTIFACT set "ARTIFACT=%%F"
        )
    )
) else (
    for /r "build\app\outputs" %%F in (*.apk *.aab) do (
        if not defined ARTIFACT set "ARTIFACT=%%F"
    )
)

if defined ARTIFACT (
    copy "!ARTIFACT!" "%OUTPUT_DIR%\app-release.apk"
    echo [OK] Saved to %OUTPUT_DIR%\app-release.apk
) else (
    echo [ERROR] No APK/AAB found!
    exit /b 1
)

:: ====== Cleanup ======
cd /d "%BUILDER_DIR%"
rmdir /S /Q "%WORK_DIR%" 2>nul
echo.
echo ============================================
echo   Build completed successfully!
echo ============================================
