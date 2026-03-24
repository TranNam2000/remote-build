@echo off
setlocal enabledelayedexpansion
title Flutter Remote Build Server
cd /d "%~dp0"
set "PROJECT_DIR=%cd%"

:: --- Auto open firewall ports 80 & 3000 ---
netsh advfirewall firewall show rule name="RemoteBuild80" >nul 2>&1
if errorlevel 1 (
    echo [!] Opening port 80...
    netsh advfirewall firewall add rule name="RemoteBuild80" dir=in action=allow protocol=tcp localport=80 >nul 2>&1
)
netsh advfirewall firewall show rule name="RemoteBuild3000" >nul 2>&1
if errorlevel 1 (
    echo [!] Opening port 3000...
    netsh advfirewall firewall add rule name="RemoteBuild3000" dir=in action=allow protocol=tcp localport=3000 >nul 2>&1
)
echo [OK] Firewall ports 80, 3000

:: --- Auto open Azure NSG ports (if az CLI available) ---
where az >nul 2>&1
if not errorlevel 1 (
    echo [*] Detecting Azure NSG...
    for /f "delims=" %%N in ('powershell -NoProfile -Command "try { $vm = az vm list -d --query \"[?powerState=='VM running'] | [0]\" -o json 2>$null | ConvertFrom-Json; $nicId = $vm.networkProfile.networkInterfaces[0].id; $nic = az network nic show --ids $nicId -o json 2>$null | ConvertFrom-Json; $nsgId = $nic.networkSecurityGroup.id; $parts = $nsgId -split '/'; $rg = $parts[4]; $nsgName = $parts[8]; Write-Output \"$rg|$nsgName\" } catch { '' }" 2^>nul') do (
        set "AZ_INFO=%%N"
    )
    if defined AZ_INFO (
        for /f "tokens=1,2 delims=|" %%A in ("!AZ_INFO!") do (
            set "AZ_RG=%%A"
            set "AZ_NSG=%%B"
        )
        if defined AZ_NSG (
            echo [*] Found NSG: !AZ_NSG! in RG: !AZ_RG!
            az network nsg rule show --resource-group "!AZ_RG!" --nsg-name "!AZ_NSG!" --name "AllowRemoteBuild" >nul 2>&1
            if errorlevel 1 (
                echo [!] Opening ports 80,3000 on Azure NSG...
                az network nsg rule create --resource-group "!AZ_RG!" --nsg-name "!AZ_NSG!" --name "AllowRemoteBuild" --priority 100 --destination-port-ranges 80 3000 --access Allow --protocol Tcp --direction Inbound >nul 2>&1
                if not errorlevel 1 (
                    echo [OK] Azure NSG ports 80, 3000 opened
                ) else (
                    echo [!] Failed to open Azure NSG. Open manually in Azure Portal.
                )
            ) else (
                echo [OK] Azure NSG rule already exists
            )
        )
    ) else (
        echo [!] Could not detect Azure NSG. If on Azure, open ports manually in Portal.
    )
) else (
    echo [i] Azure CLI not found. If on Azure VPS, install az CLI or open ports in Portal.
    echo [i] Run: winget install Microsoft.AzureCLI
)

echo ============================================
echo    Flutter Remote Build Server
echo ============================================
echo.

:: --- Detect IP (public VPS / LAN / localhost) ---
set "LAN_IP=localhost"
set "PUBLIC_IP="
set "SERVER_IP=localhost"

:: Get LAN IP
for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /i "IPv4" ^| findstr /v "127.0.0"') do (
    set "TMP_IP=%%A"
    set "TMP_IP=!TMP_IP: =!"
    if not "!TMP_IP!"=="" set "LAN_IP=!TMP_IP!"
)

:: Get public IP (VPS) - try multiple services
for /f "delims=" %%P in ('powershell -NoProfile -Command "try { (Invoke-WebRequest -Uri 'https://api.ipify.org' -TimeoutSec 3 -UseBasicParsing).Content.Trim() } catch { try { (Invoke-WebRequest -Uri 'https://icanhazip.com' -TimeoutSec 3 -UseBasicParsing).Content.Trim() } catch { '' } }" 2^>nul') do set "PUBLIC_IP=%%P"

:: Use public IP if available and different from LAN
if defined PUBLIC_IP (
    if not "!PUBLIC_IP!"=="!LAN_IP!" (
        set "SERVER_IP=!PUBLIC_IP!"
        echo [OK] Public IP ^(VPS^): !PUBLIC_IP!
        echo [OK] LAN IP: !LAN_IP!
    ) else (
        set "SERVER_IP=!LAN_IP!"
        echo [OK] LAN IP: !LAN_IP!
    )
) else (
    set "SERVER_IP=!LAN_IP!"
    echo [OK] LAN IP: !LAN_IP!
)

:: --- Chocolatey (needed for auto-install) ---
where choco >nul 2>&1
if errorlevel 1 (
    echo [!] Chocolatey not found. Installing...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
        "Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    set "PATH=%ALLUSERSPROFILE%\chocolatey\bin;%PATH%"
    :: Verify
    where choco >nul 2>&1
    if errorlevel 1 (
        echo [!] Chocolatey install failed. Please install manually:
        echo     https://chocolatey.org/install
        echo     Then re-run this script.
        pause
        exit /b 1
    )
)
echo [OK] Chocolatey

:: --- Node.js ---
where node >nul 2>&1
if errorlevel 1 (
    echo [!] Installing Node.js...
    choco install nodejs -y
    set "PATH=C:\Program Files\nodejs;%PATH%"
)
echo [OK] Node.js: & node --version

:: --- npm install ---
if not exist "backend\node_modules" (
    echo [!] Installing npm dependencies...
    cd backend && npm install && cd /d "%PROJECT_DIR%"
)

:: --- Nginx: find or install ---
set "NGINX_DIR="
set "NGINX_EXE="

:: Check if already in PATH
where nginx >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%N in ('where nginx 2^>nul') do (
        if not defined NGINX_EXE set "NGINX_EXE=%%N"
    )
)

:: Search all common locations using dir /s /b (supports wildcards properly)
if not defined NGINX_EXE (
    for /f "delims=" %%F in ('dir /s /b "C:\ProgramData\chocolatey\lib\nginx\tools\nginx.exe" 2^>nul') do (
        if not defined NGINX_EXE set "NGINX_EXE=%%F"
    )
)
if not defined NGINX_EXE (
    for /f "delims=" %%F in ('dir /s /b "C:\tools\nginx.exe" 2^>nul') do (
        if not defined NGINX_EXE set "NGINX_EXE=%%F"
    )
)
if not defined NGINX_EXE (
    if exist "C:\nginx\nginx.exe" set "NGINX_EXE=C:\nginx\nginx.exe"
)

:: Still not found? Install via choco then search again
if not defined NGINX_EXE (
    echo [!] Installing Nginx...
    choco install nginx -y
    for /f "delims=" %%F in ('dir /s /b "C:\ProgramData\chocolatey\lib\nginx\tools\nginx.exe" 2^>nul') do (
        if not defined NGINX_EXE set "NGINX_EXE=%%F"
    )
    if not defined NGINX_EXE (
        for /f "delims=" %%F in ('dir /s /b "C:\tools\nginx.exe" 2^>nul') do (
            if not defined NGINX_EXE set "NGINX_EXE=%%F"
        )
    )
    if not defined NGINX_EXE (
        for /f "delims=" %%N in ('where nginx 2^>nul') do (
            if not defined NGINX_EXE set "NGINX_EXE=%%N"
        )
    )
)

if not defined NGINX_EXE (
    echo [!] Nginx not found even after install. Running Node only on port 3000.
    goto :skip_nginx
)

:: Get directory from exe path
for %%F in ("!NGINX_EXE!") do set "NGINX_DIR=%%~dpF"
if "!NGINX_DIR:~-1!"=="\" set "NGINX_DIR=!NGINX_DIR:~0,-1!"
echo [OK] Nginx: !NGINX_EXE!

set "NGINX_CONF=!NGINX_DIR!\conf\sites\remote-build.conf"

:: --- Configure Nginx ---
if not exist "!NGINX_DIR!\conf\sites" mkdir "!NGINX_DIR!\conf\sites"

(
    echo server {
    echo     listen 80;
    echo     server_name !SERVER_IP! localhost;
    echo.
    echo     client_max_body_size 500M;
    echo.
    echo     location / {
    echo         proxy_pass http://127.0.0.1:3000;
    echo         proxy_http_version 1.1;
    echo         proxy_set_header Upgrade $http_upgrade;
    echo         proxy_set_header Connection "upgrade";
    echo         proxy_set_header Host $host;
    echo         proxy_set_header X-Real-IP $remote_addr;
    echo         proxy_buffering off;
    echo         proxy_cache off;
    echo         proxy_read_timeout 3600s;
    echo     }
    echo.
    echo     location /builds/ {
    echo         alias %PROJECT_DIR:\=/%/builder/completed_builds/;
    echo         autoindex off;
    echo     }
    echo }
) > "!NGINX_CONF!"

:: Ensure nginx.conf includes sites folder
findstr /i "sites" "!NGINX_DIR!\conf\nginx.conf" >nul 2>&1
if errorlevel 1 (
    :: Insert include before the closing brace of http block
    echo     include sites/*.conf; >> "!NGINX_DIR!\conf\nginx.conf"
)

:: Restart Nginx
echo [OK] Starting Nginx...
taskkill /f /im nginx.exe >nul 2>&1
cd /d "!NGINX_DIR!" && start "" nginx.exe && cd /d "%PROJECT_DIR%"
echo [OK] Nginx running on port 80

:skip_nginx

echo.
echo ============================================
echo    Server ready!
if defined NGINX_DIR (
    echo    http://!SERVER_IP! ^(port 80 - Nginx^)
)
echo    http://!SERVER_IP!:3000 ^(direct Node^)
echo ============================================
echo.

:: --- Start Node.js ---
cd backend
if defined NGINX_DIR (
    set "NGINX=1"
) else (
    set "NGINX=0"
)
node server.js

:: Cleanup on exit
if defined NGINX_DIR (
    taskkill /f /im nginx.exe >nul 2>&1
    del "!NGINX_CONF!" >nul 2>&1
)

echo.
echo Server da dung. Nhan phim bat ky de dong.
pause >nul
