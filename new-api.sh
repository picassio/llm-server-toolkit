#!/usr/bin/env bash
# Manage New API gateway (https://github.com/QuantumNous/new-api)
# Provides a unified OpenAI-compatible proxy in front of local llama-server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
setup_traps

NEW_API_DIR="${NEW_API_DIR:-$HOME/new-api}"
NEW_API_PORT="${NEW_API_PORT:-3000}"
COMPOSE_FILE="$NEW_API_DIR/docker-compose.yml"

usage() {
    cat <<EOF
Usage: $0 {setup|start|stop|restart|status|logs|add-channel|list-channels|create-token|nginx|update}

  setup          - Initial setup: generate config and start New API
  start          - Start New API containers
  stop           - Stop New API containers
  restart        - Restart New API containers
  status         - Show container and service health
  logs           - Show recent New API logs
  add-channel    - Add a new upstream channel (e.g., local llama-server)
  list-channels  - List configured channels
  create-token   - Create a new API token
  nginx          - Generate nginx reverse proxy config with SSL (certbot)
  reset-password - Reset admin password
  update         - Pull latest New API image and restart

Environment variables:
  NEW_API_DIR    - Installation directory (default: ~/new-api)
  NEW_API_PORT   - Port to expose (default: 3000)
EOF
    exit 1
}

# ─── Docker Compose wrapper ───────────────────────────────────────────────────
compose() {
    docker compose -f "$COMPOSE_FILE" "$@" 2>&1 | grep -v "is obsolete" || true
}

require_compose_file() {
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        log_error "New API not set up. Run: $0 setup"
        exit 1
    fi
}

require_running() {
    require_compose_file
    if ! curl -sf "http://127.0.0.1:${NEW_API_PORT}/api/status" &>/dev/null; then
        log_error "New API is not running. Run: $0 start"
        exit 1
    fi
}

# ─── Llama Server helpers ──────────────────────────────────────────────────────
check_and_offer_llama_server() {
    # Check if llama-server is already running
    if tmux has-session -t llama 2>/dev/null; then
        local port="8000"
        if [[ -f /tmp/llama-server.port ]]; then
            port=$(cat /tmp/llama-server.port)
        fi
        if curl -sf "http://127.0.0.1:${port}/health" &>/dev/null; then
            log_success "llama-server is running on port $port"
            return 0
        fi
    fi

    echo ""
    log_warn "llama-server is not running. The New API gateway needs a backend to proxy requests to."
    if confirm "Start llama-server now?" "Y"; then
        echo ""
        bash "$SCRIPT_DIR/llama-server.sh" start
    else
        echo ""
        log_info "Start it later with: bash llama-server.sh start"
    fi
}

# ─── DB helpers ────────────────────────────────────────────────────────────────
db_query() {
    docker exec new-api-postgres psql -U newapi -d new-api -t -A -c "$1" 2>/dev/null
}

# ─── Auth helpers ──────────────────────────────────────────────────────────────
# Login and get session cookie for admin API calls
COOKIE_JAR=""
login_admin() {
    COOKIE_JAR=$(mktemp /tmp/newapi-cookies-XXXXXX)
    register_temp_file "$COOKIE_JAR"

    local username password
    username=$(db_query "SELECT username FROM users WHERE role = 100 LIMIT 1;")
    if [[ -z "$username" ]]; then
        log_error "No admin user found in database."
        exit 1
    fi

    read -r -s -p "Admin password for '$username': " password
    echo ""

    local resp
    resp=$(curl -s -c "$COOKIE_JAR" "http://127.0.0.1:${NEW_API_PORT}/api/user/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$username\",\"password\":\"$password\"}")

    if ! echo "$resp" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
        log_error "Login failed. Check your password."
        exit 1
    fi

    ADMIN_USER_ID=$(echo "$resp" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['id'])")
    log_success "Logged in as $username (id=$ADMIN_USER_ID)"
}

api_call() {
    local method="$1" endpoint="$2"
    shift 2
    curl -s -b "$COOKIE_JAR" \
        -H "New-Api-User: $ADMIN_USER_ID" \
        -H "Content-Type: application/json" \
        -X "$method" \
        "http://127.0.0.1:${NEW_API_PORT}${endpoint}" \
        "$@"
}

# ─── Setup ─────────────────────────────────────────────────────────────────────
do_setup() {
    require_command docker "Install Docker: https://docs.docker.com/engine/install/"

    if [[ -f "$COMPOSE_FILE" ]]; then
        log_warn "New API already set up at $NEW_API_DIR"
        if ! confirm "Overwrite existing configuration?" "N"; then
            exit 0
        fi
    fi

    mkdir -p "$NEW_API_DIR"

    # Generate secure credentials
    local pg_password session_secret
    pg_password=$(openssl rand -hex 16)
    session_secret=$(openssl rand -hex 32)

    # Ask for port
    read -r -p "New API port [$NEW_API_PORT]: " port
    NEW_API_PORT="${port:-$NEW_API_PORT}"

    # Ask for admin credentials
    local admin_user admin_pass
    read -r -p "Admin username [admin]: " admin_user
    admin_user="${admin_user:-admin}"

    # Generate random password or let user provide one
    local generated_pass
    generated_pass=$(openssl rand -base64 16 | tr -d '/+=\n' | head -c 16)
    echo "Admin password options:"
    echo "  1) Auto-generate random password (recommended)"
    echo "  2) Enter custom password"
    read -r -p "Select [1]: " pass_choice
    pass_choice="${pass_choice:-1}"

    if [[ "$pass_choice" == "2" ]]; then
        while true; do
            read -r -s -p "Admin password (min 8 chars): " admin_pass
            echo ""
            if [[ ${#admin_pass} -ge 8 ]]; then
                break
            fi
            log_warn "Password must be at least 8 characters."
        done
    else
        admin_pass="$generated_pass"
        log_info "Generated admin password: $admin_pass"
    fi

    log_step "Generating docker-compose.yml..."

    cat > "$COMPOSE_FILE" << EOF
services:
  new-api:
    image: calciumion/new-api:latest
    container_name: new-api
    restart: always
    command: --log-dir /app/logs
    ports:
      - "${NEW_API_PORT}:3000"
    volumes:
      - ./data:/data
      - ./logs:/app/logs
    environment:
      - SQL_DSN=postgresql://newapi:${pg_password}@new-api-postgres:5432/new-api
      - REDIS_CONN_STRING=redis://new-api-redis
      - TZ=UTC
      - ERROR_LOG_ENABLED=true
      - BATCH_UPDATE_ENABLED=true
      - SESSION_SECRET=${session_secret}
    depends_on:
      new-api-redis:
        condition: service_started
      new-api-postgres:
        condition: service_healthy
    networks:
      - new-api-network
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O - http://localhost:3000/api/status | grep -o '\"success\"' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3

  new-api-redis:
    image: redis:7-alpine
    container_name: new-api-redis
    restart: always
    networks:
      - new-api-network

  new-api-postgres:
    image: postgres:16-alpine
    container_name: new-api-postgres
    restart: always
    environment:
      POSTGRES_USER: newapi
      POSTGRES_PASSWORD: ${pg_password}
      POSTGRES_DB: new-api
    volumes:
      - new-api-pg-data:/var/lib/postgresql/data
    networks:
      - new-api-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U newapi -d new-api"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  new-api-pg-data:

networks:
  new-api-network:
    driver: bridge
EOF

    log_step "Pulling images..."
    compose pull

    log_step "Starting services..."
    compose up -d

    # Wait for healthy
    log_info "Waiting for New API to start..."
    for _ in $(seq 1 30); do
        if curl -sf "http://127.0.0.1:${NEW_API_PORT}/api/status" &>/dev/null; then
            echo ""
            break
        fi
        sleep 2
        printf "."
    done

    # Create admin user and promote to admin role
    log_step "Creating admin account..."
    local reg_resp
    reg_resp=$(curl -s "http://127.0.0.1:${NEW_API_PORT}/api/user/register" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$admin_user\",\"password\":\"$admin_pass\",\"display_name\":\"Admin\"}")

    if echo "$reg_resp" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
        # Promote to admin (role 100) and set group to 'vip' (required for playground chat)
        db_query "UPDATE users SET role = 100, \"group\" = 'vip' WHERE username = '$admin_user';"
        log_success "Admin account created: $admin_user"
    else
        log_warn "Could not create admin user (may already exist)"
    fi

    # Enable self-use mode (no billing for local models)
    COOKIE_JAR=$(mktemp /tmp/newapi-cookies-XXXXXX)
    register_temp_file "$COOKIE_JAR"
    curl -s -c "$COOKIE_JAR" "http://127.0.0.1:${NEW_API_PORT}/api/user/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$admin_user\",\"password\":\"$admin_pass\"}" > /dev/null

    ADMIN_USER_ID=$(db_query "SELECT id FROM users WHERE username = '$admin_user';")
    api_call PUT "/api/option/" -d '{"key":"SelfUseModeEnabled","value":"true"}' > /dev/null
    log_info "Self-use mode enabled (no billing)"

    # Give admin unlimited quota
    db_query "UPDATE users SET quota = 100000000000 WHERE username = '$admin_user';" > /dev/null

    # Create default API token
    api_call POST "/api/token/" \
        -d '{"name":"default-token","remain_quota":0,"unlimited_quota":true}' > /dev/null
    # Token group must match user group for routing to work
    db_query "UPDATE tokens SET \"group\" = 'vip' WHERE \"group\" = '' OR \"group\" IS NULL;" > /dev/null

    local api_key
    api_key=$(db_query "SELECT key FROM tokens ORDER BY id DESC LIMIT 1;")

    # Save credentials to file
    local creds_file="$NEW_API_DIR/.credentials"
    cat > "$creds_file" <<CREDS
# New API Credentials — generated $(date -Iseconds)
# KEEP THIS FILE SECURE
NEW_API_URL=http://$(get_host_ip):${NEW_API_PORT}
NEW_API_ADMIN_USER=$admin_user
NEW_API_ADMIN_PASS=$admin_pass
NEW_API_KEY=$api_key
CREDS
    chmod 600 "$creds_file"

    echo ""
    log_success "=== New API Setup Complete ==="
    echo ""
    echo "  Web UI:     http://$(get_host_ip):${NEW_API_PORT}"
    echo "  API Base:   http://$(get_host_ip):${NEW_API_PORT}/v1"
    echo ""
    echo "  Admin:      $admin_user"
    echo "  Password:   $admin_pass"
    echo "  API Key:    $api_key"
    echo ""
    echo "  Config:     $COMPOSE_FILE"
    echo "  Creds:      $creds_file"
    echo ""
    log_info "Next steps:"
    echo "  1. Add channel:         bash new-api.sh add-channel"
    echo "  2. Test:                curl http://localhost:${NEW_API_PORT}/v1/models -H 'Authorization: Bearer $api_key'"

    # Offer to start llama-server
    check_and_offer_llama_server

    # Offer public access setup
    echo ""
    echo "Expose New API to the internet:"
    echo "  1) Cloudflare Tunnel  (recommended — zero config SSL, no open ports)"
    echo "  2) Nginx + Certbot    (traditional reverse proxy with Let's Encrypt)"
    echo "  3) Skip               (local access only)"
    read -r -p "Select [3]: " expose_choice
    expose_choice="${expose_choice:-3}"

    case "$expose_choice" in
        1)
            bash "$SCRIPT_DIR/cloudflared.sh" setup
            ;;
        2)
            do_nginx
            ;;
        *)
            log_info "You can set up public access later:"
            echo "  Cloudflare Tunnel: bash cloudflared.sh setup"
            echo "  Nginx + SSL:       bash new-api.sh nginx"
            ;;
    esac
}

# ─── Start / Stop / Restart ───────────────────────────────────────────────────
do_start() {
    require_compose_file
    log_info "Starting New API..."
    compose up -d
    log_info "Waiting for service..."
    for _ in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:${NEW_API_PORT}/api/status" &>/dev/null; then
            echo ""
            log_success "New API is running on port $NEW_API_PORT"
            check_and_offer_llama_server
            return
        fi
        sleep 2
        printf "."
    done
    echo ""
    log_warn "Service may still be starting. Check: $0 status"
}

do_stop() {
    require_compose_file
    log_info "Stopping New API..."
    compose down
    log_success "New API stopped"
}

do_restart() {
    require_compose_file
    log_info "Restarting New API..."
    compose restart
    log_info "Waiting for service..."
    for _ in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:${NEW_API_PORT}/api/status" &>/dev/null; then
            echo ""
            log_success "New API is running on port $NEW_API_PORT"
            check_and_offer_llama_server
            return
        fi
        sleep 2
        printf "."
    done
    echo ""
    log_warn "Service may still be starting."
}

# ─── Status ───────────────────────────────────────────────────────────────────
do_status() {
    require_compose_file
    echo "=== New API Status ==="
    echo ""
    compose ps
    echo ""

    if curl -sf "http://127.0.0.1:${NEW_API_PORT}/api/status" &>/dev/null; then
        local version
        version=$(curl -s "http://127.0.0.1:${NEW_API_PORT}/api/status" | \
            python3 -c "import json,sys; print(json.load(sys.stdin)['data']['version'])" 2>/dev/null || echo "unknown")
        log_success "API is healthy (version: $version, port: $NEW_API_PORT)"

        # Show channel count and model count
        local channels models
        channels=$(db_query "SELECT COUNT(*) FROM channels WHERE status = 1;" 2>/dev/null || echo "?")
        models=$(db_query "SELECT COUNT(DISTINCT unnest) FROM (SELECT unnest(string_to_array(models, ',')) FROM channels WHERE status = 1) t;" 2>/dev/null || echo "?")
        echo "  Active channels: $channels"
        echo "  Available models: $models"

        # Show tokens
        local tokens
        tokens=$(db_query "SELECT COUNT(*) FROM tokens WHERE status = 1;" 2>/dev/null || echo "?")
        echo "  Active tokens: $tokens"

        # Check llama-server backend
        echo ""
        if tmux has-session -t llama 2>/dev/null; then
            local backend_port="8000"
            if [[ -f /tmp/llama-server.port ]]; then
                backend_port=$(cat /tmp/llama-server.port)
            fi
            if curl -sf "http://127.0.0.1:${backend_port}/health" &>/dev/null; then
                log_success "llama-server backend: running (port $backend_port)"
            else
                log_warn "llama-server backend: tmux session exists but not responding"
            fi
        else
            log_warn "llama-server backend: not running"
            log_info "Start it with: bash llama-server.sh start"
        fi
    else
        log_warn "API is not responding on port $NEW_API_PORT"
    fi
}

# ─── Logs ─────────────────────────────────────────────────────────────────────
do_logs() {
    require_compose_file
    compose logs --tail 50 new-api
}

# ─── Add Channel ──────────────────────────────────────────────────────────────
do_add_channel() {
    require_running
    login_admin

    echo ""
    echo "=== Add Upstream Channel ==="
    echo ""

    # Channel name
    read -r -p "Channel name [Local llama-server]: " ch_name
    ch_name="${ch_name:-Local llama-server}"

    # Base URL — detect docker gateway for local servers
    local gateway_ip
    gateway_ip=$(docker network inspect new-api_new-api-network 2>/dev/null | \
        python3 -c "import json,sys; print(json.load(sys.stdin)[0]['IPAM']['Config'][0]['Gateway'])" 2>/dev/null || echo "172.17.0.1")

    local default_url="http://${gateway_ip}:8000"
    read -r -p "Backend URL [$default_url]: " base_url
    base_url="${base_url:-$default_url}"

    # Discover models from backend
    echo ""
    log_info "Discovering models from $base_url..."
    local discovered_models=""
    discovered_models=$(curl -sf "${base_url}/v1/models" 2>/dev/null | \
        python3 -c "import json,sys; print(','.join(m['id'] for m in json.load(sys.stdin)['data']))" 2>/dev/null || true)

    if [[ -n "$discovered_models" ]]; then
        log_success "Found models: $discovered_models"
        read -r -p "Models to register [$discovered_models]: " models
        models="${models:-$discovered_models}"
    else
        log_warn "Could not auto-discover models (is the backend running?)"
        read -r -p "Models (comma-separated): " models
        if [[ -z "$models" ]]; then
            log_error "At least one model name is required."
            exit 1
        fi
    fi

    # Create channel via API
    local resp
    resp=$(api_call POST "/api/channel/" -d "{
        \"mode\": \"multi_to_single\",
        \"channel\": {
            \"name\": \"$ch_name\",
            \"type\": 1,
            \"key\": \"no-key-needed\",
            \"base_url\": \"$base_url\",
            \"models\": \"$models\",
            \"model_mapping\": \"\",
            \"group\": \"default,vip,svip\",
            \"priority\": 1,
            \"status\": 1,
            \"weight\": 1
        }
    }")

    if echo "$resp" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
        log_success "Channel '$ch_name' created"

        # Register model metadata for each model
        IFS=',' read -ra model_arr <<< "$models"
        for model in "${model_arr[@]}"; do
            model=$(echo "$model" | xargs)  # trim whitespace
            api_call POST "/api/models/" -d "{
                \"model_name\": \"$model\",
                \"description\": \"Local model via $ch_name\",
                \"tags\": \"local\",
                \"status\": 1,
                \"name_rule\": 0
            }" > /dev/null 2>&1 || true
        done
        log_info "Model metadata registered for: $models"
    else
        log_error "Failed to create channel"
        echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
    fi
}

# ─── List Channels ────────────────────────────────────────────────────────────
do_list_channels() {
    require_running

    echo "=== Configured Channels ==="
    echo ""
    db_query "SELECT id, name, models, status FROM channels ORDER BY id;" | while IFS='|' read -r id name models status; do
        local status_icon="✅"
        [[ "$status" != "1" ]] && status_icon="❌"
        echo "  $status_icon #$id: $name"
        echo "     Models: $models"
        echo ""
    done
}

# ─── Create Token ─────────────────────────────────────────────────────────────
do_create_token() {
    require_running
    login_admin

    echo ""
    read -r -p "Token name [api-token]: " token_name
    token_name="${token_name:-api-token}"

    local resp
    resp=$(api_call POST "/api/token/" -d "{
        \"name\": \"$token_name\",
        \"remain_quota\": 0,
        \"unlimited_quota\": true
    }")

    if echo "$resp" | python3 -c "import json,sys; assert json.load(sys.stdin)['success']" 2>/dev/null; then
        # Set group on the new token
        db_query "UPDATE tokens SET \"group\" = 'vip' WHERE \"group\" = '' OR \"group\" IS NULL;" > /dev/null

        local api_key
        api_key=$(db_query "SELECT key FROM tokens WHERE name = '$token_name' ORDER BY id DESC LIMIT 1;")
        echo ""
        log_success "Token created: $token_name"
        echo "  API Key: $api_key"
        echo ""
        echo "  Usage: curl http://localhost:${NEW_API_PORT}/v1/chat/completions \\"
        echo "    -H 'Authorization: Bearer $api_key' \\"
        echo "    -H 'Content-Type: application/json' \\"
        echo "    -d '{\"model\":\"MODEL_NAME\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello\"}]}'"
    else
        log_error "Failed to create token"
        echo "$resp" | python3 -m json.tool 2>/dev/null || echo "$resp"
    fi
}

# ─── Nginx Reverse Proxy + SSL ─────────────────────────────────────────────────
generate_nginx_config() {
    local domain="$1"
    local upstream_port="$2"
    local backend_ip="${3:-127.0.0.1}"

    cat <<NGINX_EOF
# New API — Nginx reverse proxy with SSL
# Generated by llm-server-toolkit/new-api.sh
# Domain: ${domain}
#
# Install:  sudo cp this-file /etc/nginx/sites-available/${domain}
#           sudo ln -sf /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/
#           sudo nginx -t && sudo systemctl reload nginx
#
# SSL:      sudo certbot --nginx -d ${domain}

# Rate limiting zone (optional — tune as needed)
limit_req_zone \$binary_remote_addr zone=newapi_limit:10m rate=30r/s;

# Redirect HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    # Certbot ACME challenge
    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS — main server block
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${domain};

    # ─── SSL (managed by certbot) ───────────────────────────────────
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${domain}/chain.pem;

    # ─── SSL hardening ───────────────────────────────────────────
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;
    resolver_timeout 5s;

    # ─── Security headers ────────────────────────────────────────
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # ─── Proxy settings ──────────────────────────────────────────
    client_max_body_size 100M;

    # ─── API endpoints (streaming support) ──────────────────────
    location / {
        limit_req zone=newapi_limit burst=50 nodelay;

        proxy_pass http://${backend_ip}:${upstream_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # SSE / streaming support (critical for chat completions)
        proxy_http_version 1.1;
        proxy_set_header Connection '';
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;

        # Timeouts for long-running LLM requests
        proxy_connect_timeout 60s;
        proxy_send_timeout 600s;
        proxy_read_timeout 600s;
        send_timeout 600s;
    }

    # ─── Health check (no rate limit) ───────────────────────────
    location /api/status {
        proxy_pass http://${backend_ip}:${upstream_port};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF
}

do_nginx() {
    echo "=== Nginx Reverse Proxy + SSL Setup ==="
    echo ""
    echo "This generates an nginx config for reverse-proxying New API with HTTPS."
    echo "Run this on the NGINX SERVER (which may be a different machine)."
    echo ""

    # Domain
    read -r -p "Domain name (e.g., api.example.com): " DOMAIN
    if [[ -z "$DOMAIN" ]]; then
        log_error "Domain name is required."
        exit 1
    fi

    # Backend IP
    local default_backend
    default_backend=$(get_host_ip)
    read -r -p "New API backend IP [$default_backend]: " BACKEND_IP
    BACKEND_IP="${BACKEND_IP:-$default_backend}"

    # Backend port
    read -r -p "New API port [$NEW_API_PORT]: " BACKEND_PORT
    BACKEND_PORT="${BACKEND_PORT:-$NEW_API_PORT}"

    # Generate config
    local nginx_conf
    nginx_conf=$(generate_nginx_config "$DOMAIN" "$BACKEND_PORT" "$BACKEND_IP")

    echo ""
    echo "$nginx_conf"
    echo ""

    # Ask to save
    local conf_file="$NEW_API_DIR/nginx-${DOMAIN}.conf"
    if confirm "Save config to $conf_file?" "Y"; then
        mkdir -p "$NEW_API_DIR"
        echo "$nginx_conf" > "$conf_file"
        log_success "Config saved to: $conf_file"
    fi

    # Ask to install
    echo ""
    log_step "=== Installation Steps ==="
    echo ""
    echo "Run these commands on your NGINX server:"
    echo ""
    echo "  # 1. Install nginx + certbot (if not already installed)"
    echo "  sudo apt-get update"
    echo "  sudo apt-get install -y nginx certbot python3-certbot-nginx"
    echo ""
    echo "  # 2. Copy the config file"
    echo "  sudo cp $conf_file /etc/nginx/sites-available/${DOMAIN}"
    echo "  sudo ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/"
    echo ""
    echo "  # 3. Get SSL certificate (will auto-configure nginx)"
    echo "  sudo certbot --nginx -d ${DOMAIN}"
    echo ""
    echo "  # 4. Test and reload nginx"
    echo "  sudo nginx -t && sudo systemctl reload nginx"
    echo ""
    echo "  # 5. Verify auto-renewal"
    echo "  sudo certbot renew --dry-run"
    echo ""

    # Offer to install locally if this IS the nginx server
    if confirm "Install nginx + certbot and configure on THIS machine?" "N"; then
        do_nginx_install "$DOMAIN" "$BACKEND_PORT" "$BACKEND_IP" "$nginx_conf"
    else
        echo ""
        log_info "Copy the config file to your nginx server and follow the steps above."
        if [[ -f "$conf_file" ]]; then
            echo ""
            echo "  scp $conf_file user@nginx-server:/tmp/"
            echo "  ssh user@nginx-server 'sudo cp /tmp/nginx-${DOMAIN}.conf /etc/nginx/sites-available/${DOMAIN}'"
        fi
    fi
}

do_nginx_install() {
    local domain="$1" port="$2" backend_ip="$3" nginx_conf="$4"

    # Check sudo
    if ! sudo -n true 2>/dev/null; then
        log_info "sudo access required to install nginx and certbot."
        sudo true || { log_error "Cannot get sudo access."; exit 1; }
    fi

    # Install nginx + certbot
    log_step "[1/5] Installing nginx and certbot..."
    sudo apt-get update -qq
    sudo apt-get install -y nginx certbot python3-certbot-nginx

    # Write config
    log_step "[2/5] Writing nginx config..."
    echo "$nginx_conf" | sudo tee "/etc/nginx/sites-available/${domain}" > /dev/null
    sudo ln -sf "/etc/nginx/sites-available/${domain}" "/etc/nginx/sites-enabled/"

    # Remove default site if it conflicts
    if [[ -f /etc/nginx/sites-enabled/default ]]; then
        log_info "Disabling default nginx site..."
        sudo rm -f /etc/nginx/sites-enabled/default
    fi

    # Test nginx config (before SSL — will warn about missing certs, that's OK)
    log_step "[3/5] Testing nginx config..."
    if ! sudo nginx -t 2>&1; then
        log_warn "nginx config test had warnings (expected before SSL cert is obtained)"
    fi

    # Get SSL certificate
    log_step "[4/5] Obtaining SSL certificate via certbot..."
    echo ""
    read -r -p "Email for Let's Encrypt notifications: " LE_EMAIL
    if [[ -z "$LE_EMAIL" ]]; then
        log_error "Email is required for Let's Encrypt."
        exit 1
    fi

    sudo certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect

    # Reload nginx
    log_step "[5/5] Reloading nginx..."
    sudo nginx -t && sudo systemctl reload nginx

    # Verify
    echo ""
    if curl -sf "https://${domain}/api/status" &>/dev/null; then
        log_success "=== SSL reverse proxy is live! ==="
        echo ""
        echo "  Dashboard:  https://${domain}"
        echo "  API Base:   https://${domain}/v1"
        echo ""
    else
        log_warn "Could not verify https://${domain} — check DNS and firewall."
        log_info "Make sure:"
        echo "  - DNS A record for $domain points to this server's public IP"
        echo "  - Ports 80 and 443 are open in your firewall"
        echo "  - New API is running on ${backend_ip}:${port}"
    fi

    # Verify auto-renewal
    log_info "Testing certificate auto-renewal..."
    sudo certbot renew --dry-run 2>&1 | tail -3
}

# ─── Update ───────────────────────────────────────────────────────────────────
do_update() {
    require_compose_file
    log_info "Pulling latest New API image..."
    compose pull
    log_info "Restarting with new image..."
    compose up -d
    log_info "Waiting for service..."
    for _ in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:${NEW_API_PORT}/api/status" &>/dev/null; then
            echo ""
            local version
            version=$(curl -s "http://127.0.0.1:${NEW_API_PORT}/api/status" | \
                python3 -c "import json,sys; print(json.load(sys.stdin)['data']['version'])" 2>/dev/null || echo "unknown")
            log_success "Updated to version $version"
            return
        fi
        sleep 2
        printf "."
    done
    echo ""
    log_warn "Service may still be starting."
}

# ─── Reset Password ─────────────────────────────────────────────────────────
do_reset_password() {
    require_running

    # Find admin user
    local admin_user
    admin_user=$(db_query "SELECT username FROM users WHERE role = 100 LIMIT 1;")
    if [[ -z "$admin_user" ]]; then
        log_error "No admin user found in database."
        exit 1
    fi
    log_info "Admin user: $admin_user"

    # Choose random or custom
    echo ""
    echo "  1) Auto-generate random password"
    echo "  2) Enter custom password"
    read -r -p "Select [1]: " pass_choice
    pass_choice="${pass_choice:-1}"

    local new_pass
    if [[ "$pass_choice" == "2" ]]; then
        while true; do
            read -r -s -p "New password (min 8 chars): " new_pass
            echo ""
            if [[ ${#new_pass} -ge 8 ]]; then
                break
            fi
            log_warn "Password must be at least 8 characters."
        done
    else
        new_pass=$(openssl rand -base64 16 | tr -d '/+=\n' | head -c 16)
    fi

    # Hash with bcrypt — try host python3 first, then container
    local hash
    hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'${new_pass}', bcrypt.gensalt()).decode())" 2>/dev/null) ||
    hash=$(docker exec new-api python3 -c "import bcrypt; print(bcrypt.hashpw(b'${new_pass}', bcrypt.gensalt()).decode())" 2>/dev/null) || true
    if [[ -z "$hash" ]]; then
        log_error "Failed to generate password hash."
        log_info "Install bcrypt: pip install bcrypt"
        exit 1
    fi

    # Update in database
    db_query "UPDATE users SET password = '${hash}' WHERE username = '${admin_user}';" > /dev/null

    # Update credentials file
    local creds_file="$NEW_API_DIR/.credentials"
    local api_key
    api_key=$(db_query "SELECT key FROM tokens ORDER BY id DESC LIMIT 1;" || echo "")
    local host_ip
    host_ip=$(get_host_ip)

    cat > "$creds_file" <<CREDS
# New API Credentials — updated $(date -Iseconds)
# KEEP THIS FILE SECURE
NEW_API_URL=http://${host_ip}:${NEW_API_PORT}
NEW_API_ADMIN_USER=${admin_user}
NEW_API_ADMIN_PASS=${new_pass}
NEW_API_KEY=${api_key}
CREDS
    chmod 600 "$creds_file"

    echo ""
    log_success "Password reset for '$admin_user'"
    echo ""
    echo "  Username: $admin_user"
    echo "  Password: $new_pass"
    echo "  Saved to: $creds_file"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
case "${1:-}" in
    setup)          do_setup ;;
    start)          do_start ;;
    stop)           do_stop ;;
    restart)        do_restart ;;
    status)         do_status ;;
    logs)           do_logs ;;
    add-channel)    do_add_channel ;;
    list-channels)  do_list_channels ;;
    create-token)   do_create_token ;;
    nginx)          do_nginx ;;
    reset-password) do_reset_password ;;
    update)         do_update ;;
    *)              usage ;;
esac
