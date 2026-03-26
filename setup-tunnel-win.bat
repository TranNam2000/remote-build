@echo off
chcp 65001 >nul
title Cloudflare Tunnel Setup
cd /d "%~dp0"

echo ============================================
echo    Cloudflare Tunnel Setup
echo ============================================
echo.

:: --- Load credentials from tunnel.config ---
if not exist "%~dp0tunnel.config" (
    echo ERROR: tunnel.config not found. Copy tunnel.config.example and fill in your credentials.
    pause
    exit /b 1
)
for /f "usebackq eol=: tokens=1,* delims==" %%A in ("%~dp0tunnel.config") do (
    if not "%%A"=="" set "%%A=%%B"
)

:: --- Check cloudflared ---
where cloudflared >nul 2>&1
if %errorlevel% equ 0 goto cloudflared_ok

echo Installing cloudflared...
where winget >nul 2>&1
if %errorlevel% equ 0 (
    winget install --id Cloudflare.cloudflared --accept-source-agreements --accept-package-agreements
    goto check_cloudflared
)
where choco >nul 2>&1
if %errorlevel% equ 0 (
    choco install cloudflared -y
    goto check_cloudflared
)
echo ERROR: Please install cloudflared manually:
echo https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
pause
exit /b 1

:check_cloudflared
:: Refresh PATH after install using PowerShell
for /f "usebackq delims=" %%P in (`powershell -Command "[System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')"`) do set "PATH=%%P"
where cloudflared >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: cloudflared not found. Restart terminal and try again.
    pause
    exit /b 1
)

:cloudflared_ok

echo cloudflared installed OK
echo.

:: --- Kill old tunnel ---
taskkill /f /im cloudflared.exe >nul 2>&1
timeout /t 1 >nul

:: --- Check Node.js ---
where node >nul 2>&1
if %errorlevel% equ 0 goto node_ok

echo Node.js not found. Installing...
where winget >nul 2>&1
if %errorlevel% equ 0 (
    winget install --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
    goto check_node
)
where choco >nul 2>&1
if %errorlevel% equ 0 (
    choco install nodejs-lts -y
    goto check_node
)
echo ERROR: Please install Node.js manually: https://nodejs.org/
pause
exit /b 1

:check_node
:: Refresh PATH after install using PowerShell
for /f "usebackq delims=" %%P in (`powershell -Command "[System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')"`) do set "PATH=%%P"
where node >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Node.js not found after install. Restart terminal and try again.
    pause
    exit /b 1
)

:node_ok
for /f "delims=" %%N in ('where node') do set "NODE_PATH=%%N"
echo Node.js found: %NODE_PATH%

:: --- Install npm dependencies if needed ---
if not exist "%~dp0backend\node_modules" (
    echo Installing npm dependencies...
    pushd "%~dp0backend"
    call npm install
    popd
    if not exist "%~dp0backend\node_modules" (
        echo ERROR: npm install failed!
        pause
        exit /b 1
    )
    echo Dependencies installed OK
)

:: --- Start server (detect existing, offer restart) ---
powershell -Command ^
    "$conn = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; " ^
    "if ($conn -and $conn.OwningProcess -gt 0) { " ^
    "    $pid3000 = $conn.OwningProcess; " ^
    "    $proc = Get-Process -Id $pid3000 -ErrorAction SilentlyContinue; " ^
    "    Write-Host \"Port 3000 dang duoc su dung boi: $($proc.ProcessName) (PID: $pid3000)\"; " ^
    "    $choice = Read-Host 'Restart server? [Y/n]'; " ^
    "    if ($choice -eq '' -or $choice -eq 'Y' -or $choice -eq 'y') { " ^
    "        Write-Host 'Stopping old server and Java processes...'; " ^
    "        Stop-Process -Id $pid3000 -Force -ErrorAction SilentlyContinue; " ^
    "        Stop-Process -Name java,javaw -Force -ErrorAction SilentlyContinue; " ^
    "        Start-Sleep 2; " ^
    "    } else { " ^
    "        Write-Host 'Giu server cu, tiep tuc...'; " ^
    "        exit 0; " ^
    "    } " ^
    "}; " ^
    "Write-Host 'Starting build server...'; " ^
    "Start-Process -FilePath \"%NODE_PATH%\" -ArgumentList '--max-old-space-size=512', 'backend\server.js' -WorkingDirectory \"%~dp0.\" -WindowStyle Hidden; " ^
    "Start-Sleep 3; " ^
    "if (Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue) { " ^
    "    Write-Host 'Server running on port 3000' " ^
    "} else { " ^
    "    Write-Host 'Server failed to start!'; exit 1 " ^
    "}"
if %errorlevel% neq 0 (
    echo ERROR: Server failed to start on port 3000!
    pause
    exit /b 1
)

echo Chon kieu tunnel:
echo   1) Quick tunnel (random URL, khong can dang nhap)
echo   2) Named tunnel (URL co dinh, can Cloudflare account)
echo.
set /p TUNNEL_MODE="Chon [1/2] (mac dinh: 1): "
if "%TUNNEL_MODE%"=="" set TUNNEL_MODE=1

if "%TUNNEL_MODE%"=="2" goto named_tunnel
goto quick_tunnel

:named_tunnel
echo.
echo === Named Tunnel Setup ===
echo.

:: Check login
if not exist "%USERPROFILE%\.cloudflared\cert.pem" (
    echo Can dang nhap Cloudflare...
    echo Trinh duyet se mo ra, dang nhap va chon domain.
    echo.
    cloudflared tunnel login
    if %errorlevel% neq 0 (
        echo Dang nhap that bai!
        pause
        exit /b 1
    )
    echo Dang nhap thanh cong!
) else (
    echo Da dang nhap Cloudflare
)

:: Check if tunnel exists
set TUNNEL_NAME=remote-build
cloudflared tunnel list 2>nul | findstr /c:"%TUNNEL_NAME%" >nul 2>&1
if %errorlevel% neq 0 (
    echo Tao tunnel '%TUNNEL_NAME%'...
    cloudflared tunnel create %TUNNEL_NAME%
    if %errorlevel% neq 0 (
        echo Khong tao duoc tunnel!
        pause
        exit /b 1
    )
)
echo Tunnel '%TUNNEL_NAME%' ready

echo.
set /p TUNNEL_HOSTNAME="Nhap hostname (vd: build.yourdomain.com): "
if "%TUNNEL_HOSTNAME%"=="" (
    echo Can nhap hostname!
    pause
    exit /b 1
)

:: Create DNS route
echo Tao DNS route: %TUNNEL_HOSTNAME%...
cloudflared tunnel route dns %TUNNEL_NAME% %TUNNEL_HOSTNAME% 2>nul

:: Write config
powershell -Command ^
    "$tunnelId = (cloudflared tunnel list 2>$null | Select-String '%TUNNEL_NAME%' | ForEach-Object { ($_ -split '\s+')[0] }); " ^
    "$credFile = (Get-ChildItem \"$env:USERPROFILE\.cloudflared\$tunnelId.json\" -ErrorAction SilentlyContinue | Select-Object -First 1).FullName; " ^
    "if (-not $credFile) { $credFile = (Get-ChildItem \"$env:USERPROFILE\.cloudflared\*.json\" | Select-Object -First 1).FullName }; " ^
    "$config = \"tunnel: $tunnelId`ncredentials-file: $credFile`n`ningress:`n  - hostname: %TUNNEL_HOSTNAME%`n    service: http://localhost:3000`n  - service: http_status:404`n\"; " ^
    "$config | Set-Content \"$env:USERPROFILE\.cloudflared\config.yml\" -Encoding UTF8; " ^
    "Write-Host \"Config saved\"; " ^
    "Set-Clipboard \"https://%TUNNEL_HOSTNAME%\"; " ^
    "Write-Host \"URL copied to clipboard\"; " ^
    "$token = $env:TELEGRAM_TOKEN; " ^
    "$chatId = $env:TELEGRAM_CHAT_ID; " ^
    "$msg = \"*Remote Build Server Online!*`n`nhttps://%TUNNEL_HOSTNAME%`n`nURL co dinh.\"; " ^
    "if ($token) { try { Invoke-RestMethod -Uri \"https://api.telegram.org/bot$token/sendMessage\" -Method Post -Body @{chat_id=$chatId;parse_mode='Markdown';text=$msg} | Out-Null; Write-Host 'Sent to Telegram!' } catch { Write-Host 'Telegram failed.' } } else { Write-Host 'Telegram not configured, skipping.' }"

:: Update server BASE_URL with tunnel hostname
powershell -Command ^
    "try { Invoke-RestMethod -Uri 'http://localhost:3000/api/set-base-url' -Method Post -ContentType 'application/json' -Body ('{\"url\":\"https://%TUNNEL_HOSTNAME%\"}') | Out-Null; Write-Host 'BASE_URL updated: https://%TUNNEL_HOSTNAME%' } catch { Write-Host 'Warning: Could not update BASE_URL' }"

echo.
echo ============================================
echo    Starting Named Tunnel
echo    https://%TUNNEL_HOSTNAME%
echo ============================================
echo.
echo Dong cua so nay se tat tunnel.
echo.

cloudflared tunnel run %TUNNEL_NAME%
goto end

:quick_tunnel
echo.
echo Starting Quick Tunnel to http://localhost:3000
echo Waiting for URL...
echo.

powershell -ExecutionPolicy Bypass -Command ^
    "$logFile = \"$env:TEMP\tunnel.log\"; " ^
    "if (Test-Path $logFile) { Remove-Item $logFile -Force }; " ^
    "$proc = Start-Process -FilePath 'cloudflared' -ArgumentList 'tunnel','--url','http://localhost:3000' -RedirectStandardError $logFile -PassThru -NoNewWindow; " ^
    "$found = $false; " ^
    "for ($i = 0; $i -lt 30; $i++) { " ^
    "    Start-Sleep -Seconds 2; " ^
    "    if (Test-Path $logFile) { " ^
    "        $content = Get-Content $logFile -Raw -ErrorAction SilentlyContinue; " ^
    "        if ($content -match '(https://[a-z0-9-]+\.trycloudflare\.com)') { " ^
    "            $url = $Matches[1]; " ^
    "            try { Invoke-RestMethod -Uri 'http://localhost:3000/api/set-base-url' -Method Post -ContentType 'application/json' -Body ('{\"url\":\"' + $url + '\"}') | Out-Null; Write-Host 'BASE_URL updated' } catch { Write-Host 'Warning: Could not update BASE_URL' }; " ^
    "            Write-Host ''; " ^
    "            Write-Host '============================================'; " ^
    "            Write-Host '   Tunnel Ready!'; " ^
    "            Write-Host \"   $url\"; " ^
    "            Write-Host '============================================'; " ^
    "            Write-Host ''; " ^
    "            Write-Host 'URL se thay doi moi lan restart!'; " ^
    "            Set-Clipboard $url; " ^
    "            Write-Host 'Copied URL to clipboard!'; " ^
    "            $token = $env:TELEGRAM_TOKEN; " ^
    "            $chatId = $env:TELEGRAM_CHAT_ID; " ^
    "            $msg = \"*Remote Build Server Online!*`n`n$url`n`nURL tam thoi.\"; " ^
    "            if ($token) { try { Invoke-RestMethod -Uri \"https://api.telegram.org/bot$token/sendMessage\" -Method Post -Body @{chat_id=$chatId;parse_mode='Markdown';text=$msg} | Out-Null; Write-Host 'Sent to Telegram!' } catch { Write-Host 'Telegram failed.' } } else { Write-Host 'Telegram not configured, skipping.' }; " ^
    "            $found = $true; " ^
    "            break; " ^
    "        } " ^
    "    } " ^
    "}; " ^
    "if (-not $found) { Write-Host 'Timeout waiting for tunnel URL.' }; " ^
    "Write-Host ''; " ^
    "Write-Host 'Close this window to stop tunnel.'; " ^
    "Wait-Process -Id $proc.Id"


:end
echo.
echo Tunnel stopped.
pause
