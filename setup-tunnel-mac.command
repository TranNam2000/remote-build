#!/bin/bash
# Double-click file nay de tao Cloudflare Tunnel truy cap tu xa
# Ho tro: Quick tunnel (random URL) hoac Named tunnel (URL co dinh)

cd "$(dirname "$0")"

echo "============================================"
echo "   🌐 Cloudflare Tunnel Setup"
echo "============================================"
echo ""

# --- Homebrew ---
eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" || eval "$(/usr/local/bin/brew shellenv 2>/dev/null)" || true
if ! command -v brew >/dev/null 2>&1; then
    echo "📦 Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" || eval "$(/usr/local/bin/brew shellenv 2>/dev/null)" || true
fi

# --- Install cloudflared ---
if ! command -v cloudflared >/dev/null 2>&1; then
    echo "📦 Installing cloudflared..."
    brew install cloudflared
fi
echo "✅ cloudflared: $(cloudflared --version 2>&1 | head -1)"

# --- Kill old tunnel if running ---
pkill -f "cloudflared.*tunnel" 2>/dev/null || true
sleep 1

# --- Start server if not running ---
if ! lsof -ti:3000 >/dev/null 2>&1; then
    echo "🚀 Starting build server..."
    cd backend && node server.js &
    SERVER_PID=$!
    cd ..
    sleep 2
    if lsof -ti:3000 >/dev/null 2>&1; then
        echo "✅ Server running on port 3000 (PID: $SERVER_PID)"
    else
        echo "❌ Server failed to start!"
        read -p "Nhan Enter de dong."
        exit 1
    fi
else
    echo "✅ Server already running on port 3000"
fi

# --- Telegram config ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-8793252151:AAH-P7LoLGKKo5_pPBgk9MPlmVpOKsXPSN0}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-2019979030}"

send_telegram() {
    local msg="$1"
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "parse_mode=Markdown" \
        -d "text=${msg}" \
        >/dev/null 2>&1 && echo "📲 Da gui link len Telegram!" || true
}

# --- Check if named tunnel is configured ---
TUNNEL_CONFIG="$HOME/.cloudflared/config.yml"
TUNNEL_NAME="remote-build"

echo ""
echo "Chon kieu tunnel:"
echo "  1) Quick tunnel (random URL, khong can dang nhap)"
echo "  2) Named tunnel (URL co dinh, can Cloudflare account)"
echo ""
read -p "Chon [1/2] (mac dinh: 1): " TUNNEL_MODE
TUNNEL_MODE="${TUNNEL_MODE:-1}"

if [ "$TUNNEL_MODE" = "2" ]; then
    echo ""
    echo "=== Named Tunnel Setup ==="
    echo ""

    # Check login
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        echo "🔐 Can dang nhap Cloudflare..."
        echo "   Trinh duyet se mo ra, dang nhap va chon domain."
        echo ""
        cloudflared tunnel login
        if [ $? -ne 0 ]; then
            echo "❌ Dang nhap that bai!"
            read -p "Nhan Enter de dong."
            exit 1
        fi
        echo "✅ Dang nhap thanh cong!"
    else
        echo "✅ Da dang nhap Cloudflare"
    fi

    # Check if tunnel exists
    EXISTING_TUNNEL=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')

    if [ -z "$EXISTING_TUNNEL" ]; then
        echo "📦 Tao tunnel '$TUNNEL_NAME'..."
        cloudflared tunnel create "$TUNNEL_NAME"
        if [ $? -ne 0 ]; then
            echo "❌ Khong tao duoc tunnel!"
            read -p "Nhan Enter de dong."
            exit 1
        fi
        EXISTING_TUNNEL=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
        echo "✅ Tunnel ID: $EXISTING_TUNNEL"
    else
        echo "✅ Tunnel da ton tai: $EXISTING_TUNNEL"
    fi

    # Ask for hostname
    echo ""
    echo "Nhap hostname (vi du: build.yourdomain.com)"
    echo "Domain phai da duoc them vao Cloudflare."
    read -p "Hostname: " TUNNEL_HOSTNAME

    if [ -z "$TUNNEL_HOSTNAME" ]; then
        echo "❌ Can nhap hostname!"
        read -p "Nhan Enter de dong."
        exit 1
    fi

    # Create DNS route
    echo "📦 Tao DNS route: $TUNNEL_HOSTNAME → tunnel..."
    cloudflared tunnel route dns "$TUNNEL_NAME" "$TUNNEL_HOSTNAME" 2>/dev/null || true

    # Write config
    CRED_FILE=$(ls "$HOME/.cloudflared/${EXISTING_TUNNEL}.json" 2>/dev/null || ls "$HOME/.cloudflared/"*.json 2>/dev/null | head -1)
    cat > "$TUNNEL_CONFIG" << YAML
tunnel: ${EXISTING_TUNNEL}
credentials-file: ${CRED_FILE}

ingress:
  - hostname: ${TUNNEL_HOSTNAME}
    service: http://localhost:3000
  - service: http_status:404
YAML

    echo "✅ Config saved: $TUNNEL_CONFIG"
    echo ""
    echo "============================================"
    echo "   🚀 Starting Named Tunnel"
    echo "   🌐 https://$TUNNEL_HOSTNAME"
    echo "============================================"
    echo ""
    echo "⚠️  Dong cua so nay se tat tunnel."
    echo ""

    TUNNEL_URL="https://$TUNNEL_HOSTNAME"

    # Copy to clipboard
    echo "$TUNNEL_URL" | pbcopy 2>/dev/null && echo "📎 Da copy URL vao clipboard!" || true

    # Send to Telegram
    send_telegram "🌐 *Remote Build Server Online!*%0A%0A🔗 ${TUNNEL_URL}%0A%0A📱 URL co dinh, truy cap tu bat ky dau."

    # Run named tunnel
    cloudflared tunnel run "$TUNNEL_NAME"

else
    # Quick tunnel mode
    echo ""
    echo "🚀 Starting Quick Tunnel → http://localhost:3000"
    echo "⏳ Dang tao URL..."
    echo ""

    cloudflared tunnel --url http://localhost:3000 2>&1 | while IFS= read -r line; do
        if echo "$line" | grep -qE "https://.*trycloudflare\.com"; then
            TUNNEL_URL=$(echo "$line" | grep -oE "https://[a-z0-9-]+\.trycloudflare\.com")
            if [ -n "$TUNNEL_URL" ]; then
                echo ""
                echo "============================================"
                echo "   ✅ Tunnel Ready!"
                echo "   🌐 $TUNNEL_URL"
                echo "============================================"
                echo ""
                echo "📋 Copy URL tren de truy cap tu bat ky dau."
                echo "⚠️  Dong cua so nay se tat tunnel."
                echo "⚠️  URL se thay doi moi lan restart!"
                echo ""

                echo "$TUNNEL_URL" | pbcopy 2>/dev/null && echo "📎 Da copy URL vao clipboard!" || true
                send_telegram "🌐 *Remote Build Server Online!*%0A%0A🔗 ${TUNNEL_URL}%0A%0A⚠️ URL tam thoi, se thay doi khi restart."
            fi
        fi
        echo "$line"
    done
fi

echo ""
echo "Tunnel da dung. Nhan Enter de dong."
read
