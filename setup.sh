#!/bin/bash
# Pipeline Kit — VPS Setup Script
# Installs the Discord bot with SSL and systemd service.
# Supports: Ubuntu/Debian (apt), AlmaLinux/RHEL (dnf), Fedora (dnf)
set -euo pipefail

BOT_DIR="/opt/pipeline-bot"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Pipeline Bot Setup ==="

# Detect package manager
if command -v dnf &> /dev/null; then
    PKG="sudo dnf install -y"
elif command -v apt-get &> /dev/null; then
    PKG="sudo apt-get install -y"
else
    echo "ERROR: No supported package manager found (dnf or apt)"
    exit 1
fi

# 1. System packages
echo "[1/6] Installing system packages..."
$PKG python3 python3-pip unzip certbot firewalld || true

# 2. Firewall
echo "[2/6] Configuring firewall..."
sudo systemctl enable --now firewalld 2>/dev/null || true
WEBHOOK_PORT=$(grep WEBHOOK_PORT "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2 || echo "8080")
sudo firewall-cmd --permanent --add-port="${WEBHOOK_PORT}/tcp" 2>/dev/null || true
sudo firewall-cmd --permanent --add-service=http 2>/dev/null || true
sudo firewall-cmd --reload 2>/dev/null || true

# 3. SSL (optional)
echo "[3/6] SSL setup..."
SSL_DOMAIN=$(grep SSL_CERT "$SCRIPT_DIR/.env" 2>/dev/null | grep -oP '/live/\K[^/]+' || true)
if [ -n "$SSL_DOMAIN" ]; then
    echo "  Getting certificate for $SSL_DOMAIN..."
    echo "  Make sure DNS A record points to this server!"
    read -rp "  Press Enter to continue (or Ctrl+C to skip)..."
    sudo certbot certonly --standalone -d "$SSL_DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email || {
        echo "  WARNING: Certbot failed. Bot will run without SSL."
        echo "  Run manually later: sudo certbot certonly --standalone -d $SSL_DOMAIN"
    }
    sudo chmod 0755 /etc/letsencrypt/live/ /etc/letsencrypt/archive/ 2>/dev/null || true
else
    echo "  No SSL_CERT configured in .env — skipping (bot will use HTTP)"
fi

# 4. Deploy bot
echo "[4/6] Deploying bot files..."
sudo mkdir -p "$BOT_DIR"
sudo cp -rf "$SCRIPT_DIR/bot/." "$BOT_DIR/"
sudo cp -f "$SCRIPT_DIR/.env" "$BOT_DIR/.env"

# 5. Python venv
echo "[5/6] Setting up Python environment..."
cd "$BOT_DIR"
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# 6. Systemd service
echo "[6/6] Setting up systemd service..."
sudo cp -f "$SCRIPT_DIR/bot/bot.service" /etc/systemd/system/pipeline-bot.service
sudo sed -i "s|/opt/pipeline-bot|$BOT_DIR|g" /etc/systemd/system/pipeline-bot.service
sudo systemctl daemon-reload
sudo systemctl enable --now pipeline-bot.service

# Cert renewal
sudo systemctl enable --now certbot-renew.timer 2>/dev/null || {
    (sudo crontab -l 2>/dev/null; echo "0 3 * * * certbot renew --quiet --post-hook 'systemctl restart pipeline-bot'") | sudo crontab -
}

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Bot status:    sudo systemctl status pipeline-bot"
echo "Bot logs:      sudo journalctl -u pipeline-bot -f"
echo "Health check:  curl -k https://localhost:${WEBHOOK_PORT}/health"
echo ""
echo "Next: Add Linear webhook → Settings → API → Webhooks"
echo "  URL: https://$SSL_DOMAIN:${WEBHOOK_PORT}/webhook"
echo "  Events: Issue"
echo ""
