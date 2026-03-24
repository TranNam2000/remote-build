#!/bin/bash
cd "$(dirname "$0")"

echo "============================================"
echo "   Stop Remote Build Server (Port 3000)"
echo "   and Cloudflare Tunnel"
echo "============================================"
echo ""

echo "1. Stopping Node.js server on port 3000..."
if lsof -ti:3000 >/dev/null 2>&1; then
    kill -9 $(lsof -ti:3000)
fi

echo "2. Stopping Cloudflare Tunnel..."
pkill -9 -f "cloudflared" >/dev/null 2>&1

echo "3. Stopping Build Daemons (Java/Gradle, Ruby) to release file locks..."
pkill -9 -f "java" >/dev/null 2>&1
pkill -9 -f "ruby" >/dev/null 2>&1

echo ""
echo "All services stopped! You can now safely delete the folder without File in Use errors."
echo ""
read -p "Press Enter to close."
