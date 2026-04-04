#!/usr/bin/env bash
# Manage Cloudflare Tunnel for exposing New API over HTTPS
# Supports both token-based (remotely-managed) and credentials-based tunnels
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

SERVICE_NAME="cloudflared"
TUNNEL_INFO_FILE="$HOME/.cloudflared/tunnel-info"

usage() {
    cat <<EOF
Usage: $0 {setup|start|stop|restart|status|logs|dns}

  setup    - Install cloudflared and configure tunnel
  start    - Start the tunnel service
  stop     - Stop the tunnel service
  restart  - Restart the tunnel service
  status   - Show tunnel connection status
  logs     - Show recent tunnel logs
  dns      - Add/update a DNS record pointing to the tunnel

Setup requires one of:
  - Tunnel token from Cloudflare Zero Trust dashboard
  - Cloudflare API token (for DNS record creation)

How to get a tunnel token:
  1. Go to https://one.dash.cloudflare.com
  2. Navigate to: Networks → Tunnels → Create a tunnel
  3. Select "Cloudflared" connector
  4. Name your tunnel (e.g., "llm-server")
  5. Copy the token from the install command
     (the long eyJ... string after --token)
  6. In "Route tunnel" → Public hostname:
     - Subdomain: llm01 (or your choice)
     - Domain: your-domain.com
     - Service: http://localhost:3000
  7. Save the tunnel
  8. Run: bash cloudflared.sh setup
EOF
    exit 1
}

# ─── Helpers ──────────────────────────────────────────────────────────────────
require_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_info "sudo access required for cloudflared service management."
        sudo true || { log_error "Cannot get sudo access."; exit 1; }
    fi
}

save_tunnel_info() {
    local token="$1" domain="${2:-}" subdomain="${3:-}"
    mkdir -p "$(dirname "$TUNNEL_INFO_FILE")"

    # Extract tunnel ID from token
    local tunnel_id
    tunnel_id=$(python3 -c "import base64,json; print(json.loads(base64.b64decode('$token'))['t'])" 2>/dev/null || echo "unknown")

    cat > "$TUNNEL_INFO_FILE" <<EOF
# Cloudflare Tunnel Info — saved $(date -Iseconds)
TUNNEL_ID=$tunnel_id
TUNNEL_TOKEN=$token
TUNNEL_DOMAIN=$domain
TUNNEL_SUBDOMAIN=$subdomain
TUNNEL_URL=https://${subdomain}.${domain}
EOF
    chmod 600 "$TUNNEL_INFO_FILE"
}

load_tunnel_info() {
    if [[ -f "$TUNNEL_INFO_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$TUNNEL_INFO_FILE"
    fi
}

# ─── Setup ────────────────────────────────────────────────────────────────────
do_setup() {
    echo "=== Cloudflare Tunnel Setup ==="
    echo ""

    # Step 1: Install cloudflared
    if command -v cloudflared &>/dev/null; then
        log_success "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
    else
        log_step "[1/4] Installing cloudflared..."
        require_sudo

        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            source /etc/os-release
        fi

        case "${ID:-ubuntu}" in
            ubuntu|debian)
                curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg > /dev/null
                echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | \
                    sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null
                sudo apt-get update -qq
                sudo apt-get install -y cloudflared
                ;;
            *)
                # Generic install
                curl -fsSL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared
                sudo install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared
                rm -f /tmp/cloudflared
                ;;
        esac

        log_success "Installed: $(cloudflared --version 2>&1 | head -1)"
    fi

    # Step 2: Get tunnel token
    echo ""
    log_step "[2/4] Tunnel configuration"
    echo ""
    echo "You need a tunnel token from Cloudflare Zero Trust dashboard."
    echo ""
    echo "To create one:"
    echo "  1. Go to https://one.dash.cloudflare.com"
    echo "  2. Networks → Tunnels → Create a tunnel"
    echo "  3. Connector type: Cloudflared"
    echo "  4. Name it (e.g., 'llm-server')"
    echo "  5. Copy the token (starts with 'eyJ...')"
    echo "  6. Add a public hostname:"
    echo "     Subdomain: llm01, Domain: your-domain.com"
    echo "     Service type: HTTP, URL: localhost:3000"
    echo ""

    read -r -p "Tunnel token (eyJ...): " TUNNEL_TOKEN
    if [[ -z "$TUNNEL_TOKEN" || "$TUNNEL_TOKEN" != eyJ* ]]; then
        log_error "Invalid token. Must start with 'eyJ' (base64 encoded JSON)."
        exit 1
    fi

    # Validate token
    local tunnel_id account_id
    tunnel_id=$(python3 -c "import base64,json; print(json.loads(base64.b64decode('$TUNNEL_TOKEN'))['t'])" 2>/dev/null)
    account_id=$(python3 -c "import base64,json; print(json.loads(base64.b64decode('$TUNNEL_TOKEN'))['a'])" 2>/dev/null)

    if [[ -z "$tunnel_id" ]]; then
        log_error "Could not parse tunnel token."
        exit 1
    fi
    log_success "Tunnel ID: $tunnel_id"
    log_info "Account:   $account_id"

    # Step 3: DNS setup (optional)
    echo ""
    log_step "[3/4] DNS configuration (optional)"
    echo ""
    echo "If you want to auto-create a DNS record, provide a Cloudflare API token"
    echo "with DNS edit permissions. Otherwise, configure DNS in the dashboard."
    echo ""
    read -r -p "Domain name (e.g., hyper-mind.dev) [skip]: " DOMAIN
    DOMAIN="${DOMAIN:-}"

    local SUBDOMAIN=""
    if [[ -n "$DOMAIN" ]]; then
        read -r -p "Subdomain [llm01]: " SUBDOMAIN
        SUBDOMAIN="${SUBDOMAIN:-llm01}"

        read -r -p "Cloudflare API token for DNS (leave empty to skip): " CF_API_TOKEN
        if [[ -n "$CF_API_TOKEN" ]]; then
            create_dns_record "$CF_API_TOKEN" "$DOMAIN" "$SUBDOMAIN" "$tunnel_id"
        else
            echo ""
            log_info "Create this DNS record manually in Cloudflare dashboard:"
            echo "  Type:    CNAME"
            echo "  Name:    $SUBDOMAIN"
            echo "  Target:  ${tunnel_id}.cfargotunnel.com"
            echo "  Proxy:   Proxied (orange cloud)"
        fi
    fi

    # Step 4: Install as systemd service
    echo ""
    log_step "[4/4] Installing systemd service..."
    require_sudo

    # Clean up any existing installation
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}-update.service"
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}-update.timer"
    sudo systemctl daemon-reload
    sleep 1

    sudo cloudflared service install "$TUNNEL_TOKEN"

    # Save tunnel info
    save_tunnel_info "$TUNNEL_TOKEN" "$DOMAIN" "$SUBDOMAIN"

    # Verify connection
    echo ""
    log_info "Waiting for tunnel to connect..."
    sleep 5

    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        local connections
        connections=$(sudo journalctl -u "$SERVICE_NAME" --since "10 seconds ago" --no-pager 2>/dev/null | grep -c "Registered tunnel connection" || echo "0")
        log_success "Tunnel is connected ($connections connection(s) established)"
    else
        log_warn "Service started but may still be connecting. Check: bash cloudflared.sh status"
    fi

    # Test endpoint
    local full_url=""
    if [[ -n "$SUBDOMAIN" && -n "$DOMAIN" ]]; then
        full_url="https://${SUBDOMAIN}.${DOMAIN}"
        echo ""
        log_info "Testing $full_url ..."
        sleep 2
        if curl -sf "${full_url}/api/status" &>/dev/null; then
            log_success "Tunnel is live!"
        else
            log_warn "Not reachable yet. DNS may take a few minutes to propagate."
        fi
    fi

    # Print summary
    echo ""
    log_success "=== Cloudflare Tunnel Setup Complete ==="
    echo ""
    echo "  Tunnel ID:  $tunnel_id"
    echo "  Service:    cloudflared.service (enabled, auto-starts on boot)"
    if [[ -n "$full_url" ]]; then
        echo ""
        echo "  Dashboard:  $full_url"
        echo "  API Base:   ${full_url}/v1"
    fi
    echo ""
    echo "  Manage:"
    echo "    bash cloudflared.sh status     # check connection"
    echo "    bash cloudflared.sh logs       # view logs"
    echo "    bash cloudflared.sh restart    # reconnect"
    echo ""
    echo "  Traffic flow:"
    echo "    Client → Cloudflare CDN (SSL) → Tunnel → localhost:3000 (New API) → localhost:8000 (llama-server)"
}

# ─── DNS Record Creation ─────────────────────────────────────────────────────
create_dns_record() {
    local api_token="$1" domain="$2" subdomain="$3" tunnel_id="$4"

    log_info "Creating DNS record: ${subdomain}.${domain} → ${tunnel_id}.cfargotunnel.com"

    # Get zone ID
    local zone_id
    zone_id=$(curl -sf "https://api.cloudflare.com/client/v4/zones?name=${domain}" \
        -H "Authorization: Bearer $api_token" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result'][0]['id'] if d['result'] else '')" 2>/dev/null)

    if [[ -z "$zone_id" ]]; then
        log_error "Could not find zone for $domain. Check your API token has DNS permissions."
        return 1
    fi

    # Check for existing record
    local record_id
    record_id=$(curl -sf "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${subdomain}.${domain}&type=CNAME" \
        -H "Authorization: Bearer $api_token" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d['result'][0]['id'] if d['result'] else '')" 2>/dev/null)

    local method="POST" url="https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records"
    if [[ -n "$record_id" ]]; then
        method="PUT"
        url="${url}/${record_id}"
        log_info "Updating existing CNAME record..."
    else
        log_info "Creating new CNAME record..."
    fi

    local resp
    resp=$(curl -sf "$url" \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -X "$method" \
        -d "{\"type\":\"CNAME\",\"name\":\"$subdomain\",\"content\":\"${tunnel_id}.cfargotunnel.com\",\"proxied\":true,\"ttl\":1}")

    if echo "$resp" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
        log_success "DNS record created: ${subdomain}.${domain}"
    else
        log_error "Failed to create DNS record"
        echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
        return 1
    fi
}

# ─── Start / Stop / Restart ──────────────────────────────────────────────────
do_start() {
    require_sudo
    if ! systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_error "Cloudflare tunnel not set up. Run: $0 setup"
        exit 1
    fi
    log_info "Starting tunnel..."
    sudo systemctl start "$SERVICE_NAME"
    sleep 3
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "Tunnel is running"
    else
        log_error "Failed to start. Check: $0 logs"
    fi
}

do_stop() {
    require_sudo
    log_info "Stopping tunnel..."
    sudo systemctl stop "$SERVICE_NAME"
    log_success "Tunnel stopped"
}

do_restart() {
    require_sudo
    log_info "Restarting tunnel..."
    sudo systemctl restart "$SERVICE_NAME"
    sleep 5
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        log_success "Tunnel reconnected"
    else
        log_warn "Service restarted but may still be connecting. Check: $0 logs"
    fi
}

# ─── Status ──────────────────────────────────────────────────────────────────
do_status() {
    echo "=== Cloudflare Tunnel Status ==="
    echo ""

    if ! command -v cloudflared &>/dev/null; then
        log_error "cloudflared not installed. Run: $0 setup"
        exit 1
    fi

    log_info "Version: $(cloudflared --version 2>&1 | head -1)"

    if sudo systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_success "Service: running"

        local enabled="disabled"
        systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null && enabled="enabled"
        log_info "Auto-start on boot: $enabled"

        # Show connection details from logs
        local conn_lines
        conn_lines=$(sudo journalctl -u "$SERVICE_NAME" --since "1 hour ago" --no-pager 2>/dev/null | \
            grep "Registered tunnel connection" | tail -4 || true)
        local connections=0
        if [[ -n "$conn_lines" ]]; then
            connections=$(echo "$conn_lines" | wc -l)
        fi
        log_info "Active connections: $connections"

        if [[ -n "$conn_lines" ]]; then
            echo "$conn_lines" | while read -r line; do
                local location
                location=$(echo "$line" | grep -oP 'location=\K\S+' || true)
                local conn_idx
                conn_idx=$(echo "$line" | grep -oP 'connIndex=\K\S+' || true)
                if [[ -n "$location" ]]; then
                    echo "    Connection $conn_idx: $location"
                fi
            done
        fi
    else
        log_warn "Service: not running"
        log_info "Start with: $0 start"
    fi

    # Show tunnel info
    load_tunnel_info
    if [[ -n "${TUNNEL_URL:-}" ]]; then
        echo ""
        log_info "URL: $TUNNEL_URL"

        # Test reachability
        if curl -sf "${TUNNEL_URL}/api/status" &>/dev/null; then
            log_success "Endpoint: reachable"
        else
            log_warn "Endpoint: not reachable (DNS propagation may be pending)"
        fi
    fi

    # Show backend status
    echo ""
    if curl -sf "http://127.0.0.1:3000/api/status" &>/dev/null; then
        log_success "New API backend (localhost:3000): running"
    else
        log_warn "New API backend (localhost:3000): not running"
        log_info "Start with: bash new-api.sh start"
    fi
}

# ─── Logs ────────────────────────────────────────────────────────────────────
do_logs() {
    sudo journalctl -u "$SERVICE_NAME" -n 50 --no-pager
}

# ─── DNS ─────────────────────────────────────────────────────────────────────
do_dns() {
    echo "=== Add/Update DNS Record ==="
    echo ""

    load_tunnel_info
    local tunnel_id="${TUNNEL_ID:-}"

    if [[ -z "$tunnel_id" ]]; then
        read -r -p "Tunnel ID: " tunnel_id
        if [[ -z "$tunnel_id" ]]; then
            log_error "Tunnel ID is required."
            exit 1
        fi
    else
        log_info "Using tunnel: $tunnel_id"
    fi

    read -r -p "Domain (e.g., hyper-mind.dev): " domain
    read -r -p "Subdomain [llm01]: " subdomain
    subdomain="${subdomain:-llm01}"

    read -r -p "Cloudflare API token: " api_token
    if [[ -z "$api_token" ]]; then
        log_error "API token is required."
        exit 1
    fi

    create_dns_record "$api_token" "$domain" "$subdomain" "$tunnel_id"
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    setup)   do_setup ;;
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    status)  do_status ;;
    logs)    do_logs ;;
    dns)     do_dns ;;
    *)       usage ;;
esac
