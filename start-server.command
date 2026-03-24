#!/bin/bash
# Double-click file này để chạy Remote Build Server trên macOS
# Tích hợp Nginx reverse proxy (port 80 → 3000)

cd "$(dirname "$0")"
PROJECT_DIR="$(pwd)"

echo "============================================"
echo "   🚀 Flutter Remote Build Server"
echo "============================================"
echo ""

# --- Auto open firewall (macOS) ---
if command -v /usr/libexec/ApplicationFirewall/socketfilterfw >/dev/null 2>&1; then
    sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off >/dev/null 2>&1 || true
fi
echo "✅ Firewall: ports open"

# --- Homebrew ---
if ! command -v brew >/dev/null 2>&1; then
    echo "📦 Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" || eval "$(/usr/local/bin/brew shellenv 2>/dev/null)" || true

# --- Node.js ---
if ! command -v node >/dev/null 2>&1; then
    echo "📦 Installing Node.js..."
    brew install node
fi
echo "✅ Node.js: $(node --version)"

# --- npm install ---
if [ ! -d "backend/node_modules" ]; then
    echo "📦 Installing npm dependencies..."
    cd backend && npm install && cd ..
fi

# --- Nginx ---
if ! command -v nginx >/dev/null 2>&1; then
    echo "📦 Installing Nginx..."
    brew install nginx
fi
echo "✅ Nginx: $(nginx -v 2>&1)"

# --- Detect IP (public VPS → LAN → localhost) ---
PUBLIC_IP=$(curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || curl -s --connect-timeout 3 https://icanhazip.com 2>/dev/null || curl -s --connect-timeout 3 https://ifconfig.me/ip 2>/dev/null)
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
# Use public IP if available (VPS), otherwise LAN
if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "$LAN_IP" ]; then
    SERVER_IP="$PUBLIC_IP"
    echo "🌍 Public IP (VPS): $PUBLIC_IP"
    echo "🏠 LAN IP: ${LAN_IP:-none}"
else
    SERVER_IP="${LAN_IP:-localhost}"
    echo "🏠 LAN IP: $SERVER_IP"
fi

# --- Configure Nginx ---
NGINX_CONF="$(brew --prefix)/etc/nginx/servers/remote-build.conf"
mkdir -p "$(brew --prefix)/etc/nginx/servers"

cat > "$NGINX_CONF" <<NGINX
server {
    listen 80;
    server_name $SERVER_IP localhost;

    client_max_body_size 500M;

    # Frontend & API → Node.js
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # SSE support (build logs)
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    # Download builds — serve trực tiếp từ Nginx (nhanh hơn)
    location /builds/ {
        alias ${PROJECT_DIR}/builder/completed_builds/;
        autoindex off;
    }
}
NGINX

echo "✅ Nginx config: $NGINX_CONF"

# --- Restart Nginx ---
echo "🔄 Restarting Nginx..."
HAS_NGINX=0
sudo nginx -t 2>/dev/null
if [ $? -eq 0 ]; then
    sudo nginx -s stop 2>/dev/null || true
    sudo nginx
    echo "✅ Nginx running on port 80"
    HAS_NGINX=1
else
    echo "⚠️  Nginx config error! Chạy không có Nginx..."
fi

# --- Cleanup on exit ---
cleanup() {
    echo ""
    echo "🛑 Stopping server..."
    sudo nginx -s stop 2>/dev/null || true
    rm -f "$NGINX_CONF"
    echo "✅ Nginx stopped & config removed"
}
trap cleanup EXIT INT TERM

echo ""
echo "============================================"
echo "   ✅ Server ready!"
echo "   🌐 http://$SERVER_IP (port 80 - Nginx)"
echo "   🌐 http://$SERVER_IP:3000 (direct Node)"
echo "============================================"
echo ""

# --- Start Node.js ---
cd backend
export NGINX=$HAS_NGINX
node server.js

# Giữ terminal mở nếu bị lỗi
echo ""
echo "Server đã dừng. Nhấn Enter để đóng."
read
