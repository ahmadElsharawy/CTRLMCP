#!/usr/bin/env bash
# ==============================================================================
# CTRLMCP Interactive CLI Management & Control Dashboard
# ==============================================================================

TOKEN_FILE="/etc/ctrlmcp/token"
SERVICE_FILE="/etc/systemd/system/ctrlmcp.service"
NGINX_CONF="/etc/nginx/sites-available/ctrlmcp"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

read_input() {
    local prompt="$1"
    local var_name="$2"
    if [ -t 0 ]; then
        read -rp "$prompt" "$var_name" || return 1
    elif [ -c /dev/tty ] && { true < /dev/tty; } 2>/dev/null; then
        read -rp "$prompt" "$var_name" < /dev/tty || return 1
    else
        read -r "$var_name" || return 1
    fi
}

load_env() {
    MCP_PORT=$(grep -oP 'Environment="MCP_PORT=\K[0-9]+' "$SERVICE_FILE" 2>/dev/null || echo "8420")
    MCP_HTTPS_PORT=$(grep -oP 'Environment="MCP_HTTPS_PORT=\K[0-9]+' "$SERVICE_FILE" 2>/dev/null || echo "443")
    MCP_DOMAIN=$(grep -oP 'Environment="MCP_DOMAIN=\K[^"]+' "$SERVICE_FILE" 2>/dev/null || echo "localhost")
    BEARER_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]' || echo "NOT_FOUND")

    if [ "$MCP_HTTPS_PORT" = "443" ] || [ -z "$MCP_HTTPS_PORT" ]; then
        MCP_ENDPOINT="https://${MCP_DOMAIN}/mcp"
        MCP_URL_TOKEN="https://${MCP_DOMAIN}/mcp?token=${BEARER_TOKEN}"
    else
        MCP_ENDPOINT="https://${MCP_DOMAIN}:${MCP_HTTPS_PORT}/mcp"
        MCP_URL_TOKEN="https://${MCP_DOMAIN}:${MCP_HTTPS_PORT}/mcp?token=${BEARER_TOKEN}"
    fi
}

apply_new_token() {
    local NEW_TOK="$1"
    NEW_TOK="$(printf '%s' "$NEW_TOK" | tr -d '[:space:]' | tr -d '"' | tr -d "'")"
    local OLD_TOK
    OLD_TOK="$(cat "$TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')"

    if [ -z "$NEW_TOK" ]; then
        echo -e "${RED}[ERROR] Token cannot be empty.${NC}"
        return 1
    fi

    printf '%s' "$NEW_TOK" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    chown root:root "$TOKEN_FILE"

    # Safely update token in Nginx configuration without breaking symlinks
    if [ -f "$NGINX_CONF" ] && [ -n "$OLD_TOK" ]; then
        python3 -c "
import sys
path = '$NGINX_CONF'
try:
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()
    if sys.argv[1] in c:
        c = c.replace(sys.argv[1], sys.argv[2])
        with open(path, 'w', encoding='utf-8') as f:
            f.write(c)
except Exception:
    pass
" "$OLD_TOK" "$NEW_TOK" 2>/dev/null || true
    fi

    ln -sfn "$NGINX_CONF" "/etc/nginx/sites-enabled/ctrlmcp" 2>/dev/null || true

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    fi

    systemctl restart ctrlmcp.service

    # Auto-repair SSL if still on fallback
    if ! [ -f "/etc/letsencrypt/live/${MCP_DOMAIN}/fullchain.pem" ]; then
        echo -e "${YELLOW}[*] Auto-checking SSL... upgrading to official Let's Encrypt certificate...${NC}"
        iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT > /dev/null 2>&1 || true
        iptables -I INPUT 1 -p tcp --dport "$MCP_HTTPS_PORT" -j ACCEPT > /dev/null 2>&1 || true
        if certbot --nginx -d "$MCP_DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive --redirect > /dev/null 2>&1; then
            systemctl reload nginx 2>/dev/null || true
            echo -e "${GREEN}✓ SSL automatically upgraded to official Let's Encrypt!${NC}"
        fi
    fi

    # Record token change in audit log and journalctl
    local AUDIT_LOG="/var/log/ctrlmcp_audit.log"
    local TIMESTAMP
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"
    local LOG_ENTRY="[$TIMESTAMP] [TOKEN_CHANGE] Bearer token changed from '$OLD_TOK' to '$NEW_TOK' (Previous access revoked)"
    
    echo "$LOG_ENTRY" >> "$AUDIT_LOG" 2>/dev/null || true
    chmod 600 "$AUDIT_LOG" 2>/dev/null || true
    echo "$LOG_ENTRY" | systemd-cat -u ctrlmcp.service -p notice 2>/dev/null || logger -t "ctrlmcp" "$LOG_ENTRY" 2>/dev/null || true

    load_env
    echo
    echo -e "${GREEN}${BOLD}✓ Token successfully updated to:${NC} ${YELLOW}${BOLD}${NEW_TOK}${NC}"
    echo -e "${GREEN}✓ Nginx & CTRLMCP reloaded. Any previous session has been terminated!${NC}"
    echo -e "${CYAN}✓ Audit Logged:${NC} ${BOLD}$LOG_ENTRY${NC}"
    echo
    echo -e "${YELLOW}${BOLD}⚠️  CRITICAL REMINDER FOR CLAUDE WEB (claude.ai):${NC}"
    echo -e "   Since the token was changed, previous connections were terminated."
    echo -e "   You MUST update the Connector URL in Claude Web to:"
    echo -e "   ${CYAN}${BOLD}${MCP_URL_TOKEN}${NC}"
    echo -e "   ${YELLOW}(If you do not update the URL, Claude Web will show 'Couldn't reach...')${NC}"
    echo
    return 0
}

show_info() {
    load_env
    local STATUS
    STATUS=$(systemctl is-active ctrlmcp.service 2>/dev/null || echo "unknown")
    local STATUS_STR
    if [ "$STATUS" = "active" ]; then
        STATUS_STR="${GREEN}${BOLD}● ACTIVE (RUNNING)${NC}"
    else
        STATUS_STR="${RED}${BOLD}● INACTIVE ($STATUS)${NC}"
    fi

    local SSL_STATUS_STR
    if [ -f "/etc/letsencrypt/live/${MCP_DOMAIN}/fullchain.pem" ]; then
        SSL_STATUS_STR="${GREEN}${BOLD}🔒 OFFICIAL (Let's Encrypt - Valid for Claude Web)${NC}"
    else
        SSL_STATUS_STR="${YELLOW}${BOLD}⚠️  FALLBACK SELF-SIGNED (Claude Web will reject! Select [5] to fix)${NC}"
    fi

    echo -e "${CYAN}${BOLD}============================================================${NC}"
    echo -e "${BOLD}                CTRLMCP SERVER INFORMATION                  ${NC}"
    echo -e "${CYAN}${BOLD}============================================================${NC}"
    echo -e "Service Status : $STATUS_STR"
    echo -e "SSL Certificate: $SSL_STATUS_STR"
    echo -e "Public Endpoint: ${CYAN}${BOLD}${MCP_ENDPOINT}${NC}"
    echo -e "Current Token  : ${YELLOW}${BOLD}${BEARER_TOKEN}${NC}"
    echo -e "Domain Name    : ${MCP_DOMAIN}"
    if [ "$MCP_HTTPS_PORT" != "443" ]; then
        echo -e "External Port  : ${CYAN}${MCP_HTTPS_PORT}${NC}"
    fi
    echo -e "Systemd Unit   : ctrlmcp.service"
    echo
    echo -e "${GREEN}${BOLD}------------------------------------------------------------${NC}"
    echo -e "${BOLD}🔗 DIRECT CONNECTION URLS / روابط الاتصال المباشرة:${NC}"
    echo -e "${GREEN}${BOLD}------------------------------------------------------------${NC}"
    echo
    echo -e "${BOLD}1. Claude Web (claude.ai -> Customize -> Connectors):${NC}"
    echo -e "   URL            : ${CYAN}${MCP_URL_TOKEN}${NC}"
    echo -e "   Authentication : ${YELLOW}None${NC} (Direct URL Token)"
    echo -e "   Transport      : ${GREEN}Streamable HTTP${NC}"
    echo
    echo -e "${BOLD}2. ChatGPT (Desktop MCP / Custom GPTs):${NC}"
    echo -e "   Direct URL     : ${CYAN}${MCP_URL_TOKEN}${NC}"
    echo -e "   Bearer Auth    : ${YELLOW}Bearer ${BEARER_TOKEN}${NC}"
    echo
    echo -e "${BOLD}3. Claude Desktop / Cursor / VS Code (Config file):${NC}"
    cat << JSON_EOF
{
  "mcpServers": {
    "ubuntu-server": {
      "url": "${MCP_ENDPOINT}",
      "headers": {
        "Authorization": "Bearer ${BEARER_TOKEN}"
      }
    }
  }
}
JSON_EOF
    echo -e "${CYAN}${BOLD}============================================================${NC}"
}

uninstall_ctrlmcp() {
    local AUTO_CONFIRM="$1"
    echo -e "${RED}${BOLD}============================================================${NC}"
    echo -e "${RED}${BOLD}   ⚠️  CTRLMCP COMPLETE CLEAN UNINSTALL / حذف من الجذور    ${NC}"
    echo -e "${RED}${BOLD}============================================================${NC}"
    echo -e "${YELLOW}This will completely remove CTRLMCP and its configurations:${NC}"
    echo -e "  1. Stop and remove systemd service (${CYAN}ctrlmcp.service${NC})"
    echo -e "  2. Clean Nginx proxy config & SSL certificate for ${CYAN}${MCP_DOMAIN}${NC}"
    echo -e "  3. Delete virtual environment & server files in ${CYAN}/opt/ctrlmcp${NC}"
    echo -e "  4. Delete Bearer tokens & settings in ${CYAN}/etc/ctrlmcp${NC}"
    echo -e "  5. Remove shell hooks from ${CYAN}/etc/profile.d/ctrlmcp.sh${NC} & bashrc"
    echo -e "  6. Remove CLI binary (${CYAN}/usr/local/bin/ctrlmcp${NC})"
    echo
    echo -e "${GREEN}ℹ System packages (Python, Nginx, Certbot) will remain intact${NC}"
    echo -e "${GREEN}  so no other services on your server are affected.${NC}"
    echo -e "${RED}------------------------------------------------------------${NC}"

    local CONFIRM=""
    if [ "$AUTO_CONFIRM" = "-y" ] || [ "$AUTO_CONFIRM" = "--yes" ]; then
        CONFIRM="yes"
    else
        read_input "Are you sure you want to completely uninstall CTRLMCP? [type 'yes' to confirm]: " CONFIRM
        CONFIRM="$(printf '%s' "$CONFIRM" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    fi

    if [ "$CONFIRM" != "yes" ] && [ "$CONFIRM" != "y" ]; then
        echo -e "${GREEN}Uninstallation cancelled. Returning to dashboard...${NC}"
        sleep 1
        return 0
    fi

    echo
    echo -e "${BLUE}[1/6] Stopping and disabling ctrlmcp.service...${NC}"
    systemctl stop ctrlmcp.service 2>/dev/null || true
    systemctl disable ctrlmcp.service 2>/dev/null || true
    rm -f /etc/systemd/system/ctrlmcp.service /etc/systemd/system/multi-user.target.wants/ctrlmcp.service
    systemctl daemon-reload
    systemctl reset-failed ctrlmcp.service 2>/dev/null || true
    echo -e "${GREEN}  ✓ Systemd service removed.${NC}"

    echo -e "${BLUE}[2/6] Cleaning Nginx site configuration & SSL certificates...${NC}"
    rm -f /etc/nginx/sites-enabled/ctrlmcp /etc/nginx/sites-available/ctrlmcp
    if [ -f "/etc/nginx/sites-available/default" ] && [ -z "$(ls -A /etc/nginx/sites-enabled 2>/dev/null)" ]; then
        ln -sfn /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
    fi
    if [ -n "$MCP_DOMAIN" ] && [ "$MCP_DOMAIN" != "localhost" ]; then
        certbot delete --cert-name "$MCP_DOMAIN" --non-interactive 2>/dev/null || true
        rm -rf "/etc/letsencrypt/live/$MCP_DOMAIN" "/etc/letsencrypt/archive/$MCP_DOMAIN" "/etc/letsencrypt/renewal/$MCP_DOMAIN.conf" 2>/dev/null || true
    fi
    rm -f /var/www/html/install.sh
    echo -e "${GREEN}  ✓ Nginx & SSL cleaned.${NC}"

    echo -e "${BLUE}[3/6] Removing virtual environment & server files (/opt/ctrlmcp)...${NC}"
    rm -rf /opt/ctrlmcp
    echo -e "${GREEN}  ✓ /opt/ctrlmcp deleted.${NC}"

    echo -e "${BLUE}[4/6] Removing credentials, tokens & audit logs...${NC}"
    rm -rf /etc/ctrlmcp
    rm -f /var/log/ctrlmcp_audit.log
    echo -e "${GREEN}  ✓ /etc/ctrlmcp and audit logs deleted.${NC}"

    echo -e "${BLUE}[5/6] Cleaning shell integrations & hooks...${NC}"
    rm -f /etc/profile.d/ctrlmcp.sh
    sed -i '/ctrlmcp/d' /etc/bash.bashrc 2>/dev/null || true
    echo -e "${GREEN}  ✓ Shell profile hooks removed.${NC}"

    echo -e "${BLUE}[6/6] Removing CLI binary (/usr/local/bin/ctrlmcp)...${NC}"
    rm -f /usr/local/bin/ctrlmcp /usr/local/bin/CtrlMCP /usr/local/bin/CTRLMCP 2>/dev/null || true
    echo -e "${GREEN}  ✓ CLI binary removed.${NC}"

    echo
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "${GREEN}${BOLD}   ✓ CTRLMCP COMPLETELY UNINSTALLED FROM ROOTS SUCCESSFUL!  ${NC}"
    echo -e "${GREEN}${BOLD}============================================================${NC}"
    echo -e "Your server is 100% clean as if CTRLMCP was never installed."
    echo -e "To reinstall anytime on a clean slate, run:"
    echo -e "  ${CYAN}${BOLD}curl -sSL https://raw.githubusercontent.com/ahmadElsharawy/CTRLMCP/main/install.sh | bash${NC}"
    echo -e "${GREEN}============================================================${NC}"
    exit 0
}

interactive_menu() {
    if ! [ -t 0 ] && ! [ -c /dev/tty ]; then
        show_info
        exit 0
    fi

    while true; do
        clear 2>/dev/null || true
        show_info
        echo
        echo -e "${YELLOW}${BOLD}⚙️  TOKEN MANAGEMENT & OPTIONS / خيارات التحكم والتوكن:${NC}"
        echo -e "${CYAN}------------------------------------------------------------${NC}"
        echo -e "  ${YELLOW}${BOLD}[1]${NC} 🎲 Change Token to Random (تغيير التوكن عشوائياً وفصل القديم)"
        echo -e "  ${BLUE}${BOLD}[2]${NC} ✍️  Change Token to Custom (كتابة توكن مخصص من اختيارك)"
        echo -e "  ${MAGENTA}${BOLD}[3]${NC} 🔄 Restart MCP Server (إعادة تشغيل الخادم)"
        echo -e "  ${CYAN}${BOLD}[4]${NC} 📜 View Live Logs (عرض السجلات المباشرة)"
        echo -e "  ${GREEN}${BOLD}[5]${NC} 🔒 Fix / Install Official SSL (تثبيت شهادة SSL الرسمية لكلود)"
        echo -e "  ${YELLOW}${BOLD}[6]${NC} 📋 Refresh Screen (تحديث الشاشة)"
        echo -e "  ${RED}${BOLD}[7]${NC} 🗑️  Full Clean Uninstall (حذف الأداة بالكامل من جذورها)"
        echo -e "  ${RED}${BOLD}[0]${NC} 🚪 Exit (خروج)"
        echo -e "${CYAN}------------------------------------------------------------${NC}"
        
        local CHOICE=""
        if ! read_input "Choose an option [0-7]: " CHOICE; then
            echo -e "\n${GREEN}Goodbye!${NC}"
            exit 0
        fi
        CHOICE="$(printf '%s' "$CHOICE" | tr -d '[:space:]')"
        echo

        case "$CHOICE" in
            1)
                echo -e "${BLUE}[*] Generating new 256-bit cryptographically secure token...${NC}"
                local RAND_TOK
                RAND_TOK="$(openssl rand -hex 32)"
                apply_new_token "$RAND_TOK"
                read_input "Press [Enter] to refresh dashboard with new URLs..." _PAUSE
                ;;
            2)
                echo -e "${BOLD}Enter your new custom Bearer token:${NC}"
                echo -e "${YELLOW}(e.g. 21123123 or my-secret-pass)${NC}"
                local USER_TOK
                read_input "New Token: " USER_TOK
                if [ -n "$USER_TOK" ]; then
                    apply_new_token "$USER_TOK"
                else
                    echo -e "${RED}[ERROR] Token cannot be empty.${NC}"
                fi
                read_input "Press [Enter] to refresh dashboard with new URLs..." _PAUSE
                ;;
            3)
                echo -e "${BLUE}[*] Restarting ctrlmcp.service...${NC}"
                systemctl restart ctrlmcp.service
                echo -e "${GREEN}✓ Service restarted successfully.${NC}"
                sleep 1
                ;;
            4)
                echo -e "${CYAN}${BOLD}============================================================${NC}"
                echo -e "${BOLD}           LOGS & TOKEN AUDIT HISTORY / السجلات             ${NC}"
                echo -e "${CYAN}${BOLD}============================================================${NC}"
                if [ -f "/var/log/ctrlmcp_audit.log" ] && [ -s "/var/log/ctrlmcp_audit.log" ]; then
                    echo -e "${YELLOW}${BOLD}Recent Token Changes / سجل تغييرات التوكن السابقة:${NC}"
                    tail -n 10 "/var/log/ctrlmcp_audit.log"
                    echo -e "${CYAN}------------------------------------------------------------${NC}"
                fi
                echo -e "${BLUE}[*] Displaying live logs (Press ${BOLD}Ctrl+C${NC}${BLUE} to return to dashboard)...${NC}"
                sleep 1
                journalctl -u ctrlmcp.service -n 50 -f
                read_input "Press [Enter] to return to dashboard..." _PAUSE
                ;;
            5)
                echo -e "${BLUE}[*] Requesting official Let's Encrypt SSL certificate for ${MCP_DOMAIN}...${NC}"
                iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT > /dev/null 2>&1 || true
                iptables -I INPUT 1 -p tcp --dport "$MCP_HTTPS_PORT" -j ACCEPT > /dev/null 2>&1 || true
                mkdir -p /var/www/html/.well-known/acme-challenge
                chmod -R 755 /var/www/html

                local CERT_OBTAINED=0
                # Stage 1: Try Certbot Nginx plugin
                if certbot --nginx -d "$MCP_DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive --redirect; then
                    CERT_OBTAINED=1
                # Stage 2: Try Webroot challenge
                elif certbot certonly --webroot -w /var/www/html -d "$MCP_DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive; then
                    CERT_OBTAINED=1
                # Stage 3: Try Standalone mode
                else
                    echo -e "${YELLOW}[*] Trying Standalone mode (temporary socket on port 80)...${NC}"
                    systemctl stop nginx 2>/dev/null || true
                    if certbot certonly --standalone -d "$MCP_DOMAIN" --agree-tos --register-unsafely-without-email --non-interactive; then
                        CERT_OBTAINED=1
                    fi
                    systemctl start nginx 2>/dev/null || true
                fi

                if [ -f "/etc/letsencrypt/live/$MCP_DOMAIN/fullchain.pem" ]; then
                    python3 -c "
import sys, re
path = '$NGINX_CONF'
try:
    with open(path, 'r', encoding='utf-8') as f:
        c = f.read()
    c = re.sub(r'ssl_certificate\s+[^;]+;', f'ssl_certificate /etc/letsencrypt/live/{sys.argv[1]}/fullchain.pem;', c)
    c = re.sub(r'ssl_certificate_key\s+[^;]+;', f'ssl_certificate_key /etc/letsencrypt/live/{sys.argv[1]}/privkey.pem;', c)
    with open(path, 'w', encoding='utf-8') as f:
        f.write(c)
except Exception:
    pass
" "$MCP_DOMAIN" 2>/dev/null || true

                    ln -sfn "$NGINX_CONF" "/etc/nginx/sites-enabled/ctrlmcp"
                    if nginx -t > /dev/null 2>&1; then
                        systemctl reload nginx
                    fi
                    echo -e "${GREEN}${BOLD}✓ Official Let's Encrypt certificate successfully installed and activated!${NC}"
                    echo -e "${GREEN}✓ Claude Web (claude.ai) can now securely connect!${NC}"
                else
                    echo -e "${RED}[ERROR] Failed to obtain certificate.${NC}"
                    echo -e "${YELLOW}Please verify:${NC}"
                    echo -e "  1. Domain '$MCP_DOMAIN' points to this server's public IP."
                    echo -e "  2. Port 80 (HTTP) is open in your Cloud Provider's Security List / Ingress Rules."
                fi
                read_input "Press [Enter] to return to dashboard..." _PAUSE
                ;;
            6)
                ;;
            7)
                uninstall_ctrlmcp
                ;;
            0|q|Q|exit)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice: '${CHOICE}'. Please choose 0 to 7.${NC}"
                sleep 1
                ;;
        esac
    done
}

load_env
ACTION="${1:-menu}"
ACTION=$(printf '%s' "$ACTION" | tr '[:upper:]' '[:lower:]')

case "$ACTION" in
    uninstall|remove|purge)
        uninstall_ctrlmcp "$2"
        exit 0
        ;;
    status)
        systemctl status ctrlmcp.service --no-pager
        exit 0
        ;;
    restart)
        echo "Restarting ctrlmcp.service..."
        systemctl restart ctrlmcp.service
        systemctl status ctrlmcp.service --no-pager -n 10
        exit 0
        ;;
    logs|log)
        if [ -f "/var/log/ctrlmcp_audit.log" ] && [ -s "/var/log/ctrlmcp_audit.log" ]; then
            echo "=== Recent Token Changes ==="
            tail -n 10 "/var/log/ctrlmcp_audit.log"
            echo "============================"
        fi
        journalctl -u ctrlmcp.service -f
        exit 0
        ;;
    audit|token-log|token-history)
        if [ -f "/var/log/ctrlmcp_audit.log" ]; then
            cat "/var/log/ctrlmcp_audit.log"
        else
            echo "No token changes recorded yet."
        fi
        exit 0
        ;;
    token)
        echo "$BEARER_TOKEN"
        exit 0
        ;;
    rand-token|reset-token)
        RAND_TOK="$(openssl rand -hex 32)"
        apply_new_token "$RAND_TOK"
        exit 0
        ;;
    set-token|change-token)
        if [ -n "$2" ]; then
            apply_new_token "$2"
        else
            interactive_menu
        fi
        exit 0
        ;;
    info)
        show_info
        exit 0
        ;;
    menu|"")
        interactive_menu
        exit 0
        ;;
    *)
        interactive_menu
        exit 0
        ;;
esac
