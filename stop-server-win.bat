@echo off
title Stop Remote Build Server & Tunnel
echo ============================================
echo    Stop Remote Build Server (Port 3000)
echo    and Cloudflare Tunnel
echo ============================================
echo.

echo 1. Stopping Node.js server on port 3000...
powershell -Command "$conn = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1; if ($conn -and $conn.OwningProcess -gt 0) { Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue }"

echo 2. Stopping Cloudflare Tunnel...
taskkill /f /im cloudflared.exe >nul 2>&1

echo 3. Stopping all Java/Gradle processes...
taskkill /f /im java.exe /T >nul 2>&1
taskkill /f /im javaw.exe /T >nul 2>&1

echo.
echo All services stopped! You can now safely delete the folder without "File in Use" errors.
pause
