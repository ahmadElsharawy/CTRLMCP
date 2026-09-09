#!/usr/bin/env bash
# ==============================================================================
# CTRLMCP - Generic Server Administrative MCP Server Installer
# Target OS: Ubuntu 20.04 / 22.04 / 24.04 LTS
# Protocol: MCP Streamable HTTP (Model Context Protocol)
# Privileges: Root
# Security: Nginx Reverse Proxy + Let's Encrypt TLS + Strong Bearer Token Auth
# ==============================================================================

set -eo pipefail

# Color formatting
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${CYAN}${BOLD}"
cat << "EOF"
  ██████╗████████╗██████╗ ██╗     ███╗   ███╗ ██████╗██████╗ 
 ██╔════╝╚══██╔══╝██╔══██╗██║     ████╗ ████║██╔════╝██╔══██╗
 ██║        ██║   ██████╔╝██║     ██╔████╔██║██║     ██████╔╝
 ██║        ██║   ██╔══██╗██║     ██║╚██╔╝██║██║     ██╔═══╝ 
 ╚██████╗   ██║   ██║  ██║███████╗██║ ╚═╝ ██║╚██████╗██║     
  ╚═════╝   ╚═╝   ╚═╝  ╚═╝╚══════╝╚═╝     ╚═╝ ╚═════╝╚═╝     
  Generic Administrative MCP Server - Automated Installer
EOF
echo -e "${NC}"

# ==============================================================================
# STEP 0: ROOT PRIVILEGE CHECK
# ==============================================================================
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[ERROR] This installer must be run as root.${NC}"
    echo -e "Please execute: ${BOLD}sudo bash install.sh${NC}"
    exit 1
fi

# ==============================================================================
# STEP 1: INTERACTIVE USER INPUTS (PORT & DOMAIN)
# ==============================================================================
echo -e "${BLUE}${BOLD}[Configuring Environment]${NC}"

# Helper to read from terminal or stdin safely
prompt_read() {
    local prompt="$1"
    local var_name="$2"
    if [ -t 0 ]; then
        read -rp "$prompt" "$var_name"
    elif [ -c /dev/tty ] && { true < /dev/tty; } 2>/dev/null; then
        read -rp "$prompt" "$var_name" < /dev/tty
    else
        read -t 2 -r "$var_name" 2>/dev/null || true
    fi
}

# Step 1.1: Detect Server Public IP
echo -e "${BLUE}[*] Detecting server public IP address...${NC}"
SERVER_PUBLIC_IP="$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || curl -s4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || curl -s4 --connect-timeout 5 https://icanhazip.com 2>/dev/null || echo "")"
SERVER_PUBLIC_IP="$(printf '%s' "$SERVER_PUBLIC_IP" | tr -d '[:space:]')"

if [ -n "$SERVER_PUBLIC_IP" ]; then
    echo -e "${GREEN}  ✓ Server Public IP: ${BOLD}${SERVER_PUBLIC_IP}${NC}"
else
    echo -e "${YELLOW}  [WARNING] Could not automatically detect public IP. Continuing...${NC}"
fi

# 1. Internal MCP port (Automatic: 8420, internal-only 127.0.0.1)
MCP_PORT="${MCP_PORT:-8420}"
if command -v ss > /dev/null 2>&1; then
    while ss -tuln | grep -q ":${MCP_PORT} "; do
        MCP_PORT=$((MCP_PORT + 1))
    done
fi
echo -e "  ✓ Internal Port : ${CYAN}${MCP_PORT}${NC} (automatic / internal 127.0.0.1)"

# 2. Nginx internal HTTPS port - ALWAYS 443 (Nginx listens on this inside the server)
MCP_NGINX_PORT=443
echo -e "  ✓ Nginx Internal Port : ${CYAN}${MCP_NGINX_PORT}${NC} (fixed - Nginx always listens on 443 internally)"

# 3a. External/Public HTTPS port (what users connect to - may differ if behind NAT)
#     If behind NAT (e.g. external 5454 → internal 443), set this to the external port.
#     If using standard HTTPS (external 443 → internal 443), leave as 443.
if [ -n "$MCP_HTTPS_PORT" ]; then
    echo -e "  ✓ External HTTPS Port : ${CYAN}${MCP_HTTPS_PORT}${NC} (from environment)"
elif [ -t 0 ] || { [ -c /dev/tty ] && { true < /dev/tty; } 2>/dev/null; }; then
    prompt_read "Enter External/Public HTTPS Port [443]: " INPUT_HTTPS_PORT
    MCP_HTTPS_PORT="${INPUT_HTTPS_PORT:-443}"
else
    MCP_HTTPS_PORT="443"
fi
echo -e "  ✓ External HTTPS Port : ${CYAN}${MCP_HTTPS_PORT}${NC} (public-facing port in your URL)"
if [ "$MCP_HTTPS_PORT" != "443" ]; then
    echo -e "${CYAN}  ℹ  NAT mode: External ${MCP_HTTPS_PORT} → Internal ${MCP_NGINX_PORT} (Nginx)${NC}"
fi

# 3. Domain Name (interactive or from environment)
while true; do
    if [ -z "$MCP_DOMAIN" ]; then
        prompt_read "Enter MCP Domain (mandatory, e.g. mcp.example.com): " RAW_DOMAIN
        MCP_DOMAIN="$(printf '%s' "$RAW_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|[[:space:]]||g')"
    else
        MCP_DOMAIN="$(printf '%s' "$MCP_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed -e 's|^https\?://||' -e 's|/.*$||' -e 's|[[:space:]]||g')"
        echo -e "  - Domain Name   : ${CYAN}${MCP_DOMAIN}${NC} (from environment)"
    fi

    if [ -z "$MCP_DOMAIN" ]; then
        echo -e "${YELLOW}[WARNING] Domain is mandatory. Please enter a valid domain name.${NC}"
        continue
    fi

    echo -e "${BLUE}[*] Checking DNS resolution for '${MCP_DOMAIN}'...${NC}"
    # Resolve domain using Google DNS 8.8.8.8 and local resolver
    DOMAIN_IP=""
    if command -v dig > /dev/null 2>&1; then
        DOMAIN_IP="$(dig +short "$MCP_DOMAIN" @8.8.8.8 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1 || true)"
    fi
    if [ -z "$DOMAIN_IP" ]; then
        DOMAIN_IP="$(getent ahostsv4 "$MCP_DOMAIN" 2>/dev/null | awk '{print $1}' | head -n 1 || true)"
    fi
    DOMAIN_IP="$(printf '%s' "$DOMAIN_IP" | tr -d '[:space:]')"

    if [ -z "$DOMAIN_IP" ]; then
        echo -e "${RED}[ERROR] Domain '${MCP_DOMAIN}' does not resolve to any IP address!${NC}"
        if [ -n "$SERVER_PUBLIC_IP" ]; then
            echo -e "${YELLOW}Please create an A-Record in your DNS pointing '${MCP_DOMAIN}' -> '${SERVER_PUBLIC_IP}'.${NC}"
        fi
        prompt_read "Do you want to continue anyway (e.g. testing with local hosts file)? [y/N]: " FORCE_DNS
        if [[ "$FORCE_DNS" =~ ^[Yy] ]]; then
            break
        fi
        continue
    fi

    echo -e "  - Resolved IP : ${CYAN}${DOMAIN_IP}${NC}"
    if [ -n "$SERVER_PUBLIC_IP" ] && [ "$DOMAIN_IP" != "$SERVER_PUBLIC_IP" ]; then
        echo -e "${RED}[WARNING] DNS MISMATCH!${NC}"
        echo -e "    Domain '${MCP_DOMAIN}' points to : ${RED}${DOMAIN_IP}${NC}"
        echo -e "    This server's Public IP is       : ${GREEN}${SERVER_PUBLIC_IP}${NC}"
        echo -e "${YELLOW}Let's Encrypt SSL and external MCP clients will fail unless the domain points to this server.${NC}"
        prompt_read "Do you want to ignore this mismatch and continue anyway? [y/N]: " IGNORE_MISMATCH
        if [[ "$IGNORE_MISMATCH" =~ ^[Yy] ]]; then
            break
        fi
        continue
    fi

    echo -e "${GREEN}  ✓ Domain '${MCP_DOMAIN}' is correctly pointed to this server (${SERVER_PUBLIC_IP})!${NC}"
    break
done

# Step 1.3: Check and open firewall ports (80, MCP_HTTPS_PORT)
echo -e "${BLUE}[*] Checking firewall (UFW) for ports 80 and ${MCP_HTTPS_PORT}...${NC}"
if command -v ufw > /dev/null 2>&1 && ufw status 2>/dev/null | grep -qw "active"; then
    echo -e "${YELLOW}  [!] UFW is active. Ensuring ports 80 and ${MCP_HTTPS_PORT} are allowed...${NC}"
    ufw allow 80/tcp > /dev/null 2>&1 || true
    ufw allow "${MCP_HTTPS_PORT}/tcp" > /dev/null 2>&1 || true
    echo -e "${GREEN}  ✓ Ports 80 and ${MCP_HTTPS_PORT} allowed in UFW firewall.${NC}"
else
    echo -e "${GREEN}  ✓ Local server firewall allows ports 80 and ${MCP_HTTPS_PORT}.${NC}"
fi
echo -e "${CYAN}  ℹ NOTE: Please ensure Ports 80 and ${MCP_HTTPS_PORT} are open in your Cloud Provider's Firewall / Security List (Oracle Cloud, AWS, GCP, etc.).${NC}"
echo -e "${CYAN}  ℹ NOTE: Port ${MCP_PORT} is internal-only (127.0.0.1) and does NOT need to be opened externally.${NC}"

# Step 1.4: Let's Encrypt Contact Email (from env or skip)
if [ -n "$LE_EMAIL" ]; then
    LE_EMAIL="$(printf '%s' "$LE_EMAIL" | tr -d '[:space:]')"
    echo -e "${GREEN}  ✓ SSL contact email set to: ${CYAN}${LE_EMAIL}${NC}"
elif [ -t 0 ] || { [ -c /dev/tty ] && { true < /dev/tty; } 2>/dev/null; }; then
    prompt_read "Enter email for Let's Encrypt renewal notices (optional, press Enter to skip): " INPUT_EMAIL
    INPUT_EMAIL="$(printf '%s' "$INPUT_EMAIL" | tr -d '[:space:]')"
    if [ -n "$INPUT_EMAIL" ]; then
        LE_EMAIL="$INPUT_EMAIL"
        echo -e "${GREEN}  ✓ SSL contact email set to: ${CYAN}${LE_EMAIL}${NC}"
    else
        LE_EMAIL=""
        echo -e "${CYAN}  ✓ Registering without email (--register-unsafely-without-email).${NC}"
    fi
else
    LE_EMAIL=""
    echo -e "${CYAN}  ✓ Registering without email (non-interactive mode).${NC}"
fi

echo
echo -e "${GREEN}------------------------------------------------------------${NC}"
# Step 1.5: Bearer Token (Custom or Auto-generated)
if [ -n "$MCP_BEARER_TOKEN" ]; then
    BEARER_TOKEN="$(printf '%s' "$MCP_BEARER_TOKEN" | tr -d '[:space:]' | tr -d '"' | tr -d "'")"
    echo -e "  - Bearer Token  : ${YELLOW}${BEARER_TOKEN}${NC} (from environment)"
elif [ -t 0 ] || { [ -c /dev/tty ] && { true < /dev/tty; } 2>/dev/null; }; then
    prompt_read "Enter custom Bearer token (press Enter to auto-generate secure token): " INPUT_TOKEN
    INPUT_TOKEN="$(printf '%s' "$INPUT_TOKEN" | tr -d '[:space:]' | tr -d '"' | tr -d "'")"
    if [ -n "$INPUT_TOKEN" ]; then
        BEARER_TOKEN="$INPUT_TOKEN"
        echo -e "${GREEN}  ✓ Using custom Bearer token: ${YELLOW}${BEARER_TOKEN}${NC}"
    else
        BEARER_TOKEN="$(openssl rand -hex 32)"
        echo -e "${GREEN}  ✓ Auto-generated random 256-bit secure Bearer token.${NC}"
    fi
else
    BEARER_TOKEN="$(openssl rand -hex 32)"
    echo -e "${GREEN}  ✓ Auto-generated random 256-bit secure Bearer token (non-interactive mode).${NC}"
fi

if [ "$MCP_HTTPS_PORT" = "443" ] || [ -z "$MCP_HTTPS_PORT" ]; then
    MCP_ENDPOINT="https://${MCP_DOMAIN}/mcp"
    MCP_URL_TOKEN="https://${MCP_DOMAIN}/mcp?token=${BEARER_TOKEN}"
else
    MCP_ENDPOINT="https://${MCP_DOMAIN}:${MCP_HTTPS_PORT}/mcp"
    MCP_URL_TOKEN="https://${MCP_DOMAIN}:${MCP_HTTPS_PORT}/mcp?token=${BEARER_TOKEN}"
fi

echo -e "${BOLD}Configuration Summary:${NC}"
echo -e "  - Internal Port : ${CYAN}${MCP_PORT}${NC}"
echo -e "  - External Port : ${CYAN}${MCP_HTTPS_PORT}${NC}"
echo -e "  - Domain Name   : ${CYAN}${MCP_DOMAIN}${NC}"
if [ -n "$LE_EMAIL" ]; then
    echo -e "  - SSL Contact   : ${CYAN}${LE_EMAIL}${NC}"
else
    echo -e "  - SSL Contact   : ${CYAN}Unregistered / No email${NC}"
fi
echo -e "  - Public Target : ${CYAN}${MCP_ENDPOINT}${NC}"
echo -e "  - Direct URL    : ${CYAN}${MCP_URL_TOKEN}${NC}"
echo -e "${GREEN}------------------------------------------------------------${NC}"
echo

# ==============================================================================
# STEP 2: DIRECTORY SETUP & TOKEN GENERATION
# ==============================================================================
APP_DIR="/opt/ctrlmcp"
CONF_DIR="/etc/ctrlmcp"
VENV_DIR="$APP_DIR/venv"
SERVER_FILE="$APP_DIR/server.py"
SERVICE_FILE="/etc/systemd/system/ctrlmcp.service"
NGINX_AVAILABLE="/etc/nginx/sites-available/ctrlmcp"
NGINX_ENABLED="/etc/nginx/sites-enabled/ctrlmcp"
TOKEN_FILE="$CONF_DIR/token"

echo -e "${BLUE}[1/8] Creating directories and generating root-only Bearer Token...${NC}"
mkdir -p "$APP_DIR" "$CONF_DIR"
chmod 700 "$APP_DIR" "$CONF_DIR"

printf '%s' "$BEARER_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
chown root:root "$TOKEN_FILE"
echo -e "${GREEN}  ✓ Saved Bearer token in ${TOKEN_FILE}${NC}"

# ==============================================================================
# STEP 3: SYSTEM PACKAGES INSTALLATION
# ==============================================================================
echo -e "${BLUE}[2/8] Installing required system packages via apt...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=120 update -y > /dev/null
apt-get -o DPkg::Lock::Timeout=120 install -y \
    python3 \
    python3-venv \
    python3-pip \
    nginx \
    certbot \
    python3-certbot-nginx \
    curl \
    jq \
    openssl \
    ca-certificates \
    lsof \
    procps \
    iproute2 \
    dnsutils \
    iputils-ping \
    net-tools > /dev/null
echo -e "${GREEN}  ✓ System packages installed successfully.${NC}"

# ==============================================================================
# STEP 4: PYTHON VIRTUAL ENVIRONMENT & MCP SDK
# ==============================================================================
echo -e "${BLUE}[3/8] Configuring Python virtual environment and MCP SDK...${NC}"
if [ ! -f "$VENV_DIR/bin/python" ]; then
    python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade pip setuptools wheel > /dev/null
"$VENV_DIR/bin/pip" install "mcp[cli]" uvicorn starlette pydantic httpx > /dev/null
echo -e "${GREEN}  ✓ Python environment and MCP SDK configured.${NC}"

# ==============================================================================
# STEP 5: MCP SERVER APPLICATION CODE (/opt/ctrlmcp/server.py)
# ==============================================================================
echo -e "${BLUE}[4/8] Generating Administrative MCP Server code...${NC}"

cat << 'PYEOF' > "$SERVER_FILE"
#!/usr/bin/env python3
"""
CTRLMCP - Generic Administrative MCP Server
Streamable HTTP transport running as root on Ubuntu.
"""

import os
import sys
import json
import socket
import shutil
import subprocess
from pathlib import Path
from typing import Any, Optional

try:
    from mcp.server.mcpserver import MCPServer
except ImportError:
    try:
        from mcp.server.fastmcp import FastMCP as MCPServer
    except ImportError:
        from mcp.server import Server as MCPServer

try:
    from mcp.server.transport_security import TransportSecuritySettings
except ImportError:
    TransportSecuritySettings = None

MCP_PORT = int(os.environ.get("MCP_PORT", "8420"))
MCP_HTTPS_PORT = int(os.environ.get("MCP_HTTPS_PORT", "443"))
MCP_DOMAIN = os.environ.get("MCP_DOMAIN", "localhost")
MCP_TOKEN_FILE = os.environ.get("MCP_TOKEN_FILE", "/etc/ctrlmcp/token")

def get_auth_token() -> str:
    """Read Bearer token from token file or environment."""
    if os.environ.get("MCP_BEARER_TOKEN"):
        return os.environ["MCP_BEARER_TOKEN"].strip()
    if os.path.exists(MCP_TOKEN_FILE):
        try:
            with open(MCP_TOKEN_FILE, "r", encoding="utf-8") as f:
                return f.read().strip()
        except Exception as e:
            print(f"Warning: Could not read token file {MCP_TOKEN_FILE}: {e}", file=sys.stderr)
    return ""

AUTH_TOKEN = get_auth_token()

allowed_hosts = [
    "127.0.0.1",
    f"127.0.0.1:{MCP_PORT}",
    "localhost",
    f"localhost:{MCP_PORT}",
]
if MCP_DOMAIN and MCP_DOMAIN not in ["localhost", "127.0.0.1"]:
    allowed_hosts.extend([
        MCP_DOMAIN,
        f"{MCP_DOMAIN}:80",
        f"{MCP_DOMAIN}:443",
        f"{MCP_DOMAIN}:{MCP_HTTPS_PORT}",
        f"{MCP_DOMAIN}:{MCP_PORT}",
        f"{MCP_DOMAIN}:*",
    ])

allowed_origins = [
    "http://127.0.0.1",
    f"http://127.0.0.1:{MCP_PORT}",
    "http://localhost",
    f"http://localhost:{MCP_PORT}",
]
if MCP_DOMAIN and MCP_DOMAIN not in ["localhost", "127.0.0.1"]:
    allowed_origins.extend([
        f"https://{MCP_DOMAIN}",
        f"http://{MCP_DOMAIN}",
        f"https://{MCP_DOMAIN}:{MCP_HTTPS_PORT}",
        f"https://{MCP_DOMAIN}:443",
        f"http://{MCP_DOMAIN}:80",
    ])

security_settings = None
if TransportSecuritySettings:
    try:
        security_settings = TransportSecuritySettings(enable_dns_rebinding_protection=False)
    except Exception:
        pass

mcp = MCPServer(
    "CTRLMCP-Server",
    instructions="Comprehensive system administration and diagnostics MCP server running as root on Ubuntu.",
)

# -------------------------------------------------------------
# 23 Administrative Tools
# -------------------------------------------------------------

@mcp.tool()
def run_command(command: str, timeout: int = 300) -> str:
    """Execute a bash command with full root privileges. Returns returncode, stdout, and stderr."""
    try:
        proc = subprocess.run(
            command,
            shell=True,
            executable="/bin/bash",
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return json.dumps({
            "returncode": proc.returncode,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
        }, indent=2)
    except subprocess.TimeoutExpired:
        return json.dumps({"error": f"Command timed out after {timeout} seconds"}, indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)}, indent=2)

@mcp.tool()
def system_info() -> str:
    """Get general system overview: host, uptime, kernel, load averages, memory, and disk."""
    info: dict[str, Any] = {}
    info["hostname"] = socket.gethostname()
    try:
        with open("/proc/loadavg", "r", encoding="utf-8") as f:
            loads = f.read().strip().split()
            info["load_average"] = {"1m": loads[0], "5m": loads[1], "15m": loads[2]}
    except Exception as e:
        info["load_average_error"] = str(e)

    try:
        uptime_out = subprocess.check_output(["uptime", "-p"], text=True).strip()
        info["uptime"] = uptime_out
    except Exception:
        info["uptime"] = "unknown"

    try:
        info["uname"] = subprocess.check_output(["uname", "-srmn"], text=True).strip()
    except Exception:
        pass

    try:
        df_out = subprocess.check_output(["df", "-h", "/"], text=True).strip()
        info["root_filesystem"] = df_out
    except Exception:
        pass

    try:
        free_out = subprocess.check_output(["free", "-h"], text=True).strip()
        info["memory_summary"] = free_out
    except Exception:
        pass

    return json.dumps(info, indent=2)

@mcp.tool()
def current_user() -> str:
    """Get current executing user, UID, GID, and effective groups."""
    data: dict[str, Any] = {
        "user": os.environ.get("USER", "root"),
        "uid": os.getuid() if hasattr(os, "getuid") else 0,
        "gid": os.getgid() if hasattr(os, "getgid") else 0,
    }
    try:
        id_out = subprocess.check_output(["id"], text=True).strip()
        data["id_output"] = id_out
    except Exception:
        pass
    return json.dumps(data, indent=2)

@mcp.tool()
def hostname() -> str:
    """Get system hostname and FQDN."""
    short_name = socket.gethostname()
    fqdn = socket.getfqdn()
    return json.dumps({"hostname": short_name, "fqdn": fqdn}, indent=2)

@mcp.tool()
def uname() -> str:
    """Get detailed kernel and system architecture information."""
    try:
        out = subprocess.check_output(["uname", "-a"], text=True).strip()
        return out
    except Exception as e:
        return f"Error: {e}"

@mcp.tool()
def operating_system() -> str:
    """Get Linux distribution details from /etc/os-release."""
    data: dict[str, str] = {}
    os_release = Path("/etc/os-release")
    if os_release.exists():
        for line in os_release.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip().strip('"')
        return json.dumps(data, indent=2)
    return json.dumps({"error": "/etc/os-release not found"}, indent=2)

@mcp.tool()
def cpu_info() -> str:
    """Get CPU model, architecture, core counts, and frequency information."""
    try:
        lscpu_out = subprocess.check_output(["lscpu"], text=True).strip()
        return lscpu_out
    except Exception:
        try:
            with open("/proc/cpuinfo", "r", encoding="utf-8") as f:
                lines = [line.strip() for line in f if "model name" in line or "cpu MHz" in line]
                return "\n".join(lines[:10])
        except Exception as e:
            return f"Error reading CPU info: {e}"

@mcp.tool()
def memory_info() -> str:
    """Get detailed RAM and Swap memory utilization."""
    try:
        free_out = subprocess.check_output(["free", "-m"], text=True).strip()
        meminfo_path = Path("/proc/meminfo")
        top_lines = []
        if meminfo_path.exists():
            for line in meminfo_path.read_text(encoding="utf-8").splitlines()[:15]:
                top_lines.append(line)
        return free_out + "\n\n/proc/meminfo (top entries):\n" + "\n".join(top_lines)
    except Exception as e:
        return f"Error: {e}"

@mcp.tool()
def disk_usage(path: str = "/") -> str:
    """Get disk space utilization for all mounted filesystems or a specific path."""
    try:
        df_all = subprocess.check_output(["df", "-hT"], text=True).strip()
        df_target = subprocess.check_output(["df", "-h", path], text=True).strip()
        return f"=== All Mounts ===\n{df_all}\n\n=== Target: {path} ===\n{df_target}"
    except Exception as e:
        return f"Error: {e}"

@mcp.tool()
def directory_list(path: str = "/", show_hidden: bool = False) -> str:
    """List directory entries with detailed file types, sizes, and permissions."""
    p = Path(path)
    if not p.exists():
        return f"Error: Path does not exist: {path}"
    if not p.is_dir():
        return f"Error: Path is not a directory: {path}"
    try:
        entries = []
        for item in sorted(p.iterdir(), key=lambda x: (not x.is_dir(), x.name.lower())):
            if not show_hidden and item.name.startswith("."):
                continue
            try:
                st = item.stat()
                mode_str = oct(st.st_mode)[-4:]
                size_str = str(st.st_size)
                ftype = "DIR" if item.is_dir() else ("LINK" if item.is_symlink() else "FILE")
                entries.append(f"[{ftype}] {mode_str} {size_str:>10}B  {item.name}")
            except Exception as item_err:
                entries.append(f"[ERR] {item.name} ({item_err})")
        return "\n".join(entries) if entries else "(empty directory)"
    except Exception as e:
        return f"Error: {e}"

@mcp.tool()
def file_read(path: str, max_bytes: int = 1048576, offset: int = 0) -> str:
    """Read content of a file up to max_bytes (default 1MB)."""
    p = Path(path)
    if not p.exists():
        return f"Error: File does not exist: {path}"
    if not p.is_file():
        return f"Error: Path is not a regular file: {path}"
    try:
        file_size = p.stat().st_size
        with open(p, "rb") as f:
            if offset > 0:
                f.seek(offset)
            data = f.read(max_bytes)
        try:
            text = data.decode("utf-8")
            truncated = (offset + len(data)) < file_size
            header = f"=== File: {path} (Size: {file_size} bytes, Read: {len(data)} bytes, Offset: {offset}) ===\n"
            footer = "\n[... Content truncated due to max_bytes limit ...]" if truncated else ""
            return header + text + footer
        except UnicodeDecodeError:
            return f"Binary file detected: {path} (Size: {file_size} bytes). Cannot display as UTF-8 text."
    except Exception as e:
        return f"Error reading file: {e}"

@mcp.tool()
def file_exists(path: str) -> str:
    """Check if a path exists and get its metadata (type, size, permissions, owner)."""
    p = Path(path)
    if not p.exists():
        return json.dumps({"exists": False, "path": path}, indent=2)
    try:
        st = p.stat()
        return json.dumps({
            "exists": True,
            "path": path,
            "is_file": p.is_file(),
            "is_dir": p.is_dir(),
            "is_symlink": p.is_symlink(),
            "size_bytes": st.st_size,
            "mode": oct(st.st_mode),
            "uid": st.st_uid,
            "gid": st.st_gid,
            "mtime": st.st_mtime,
        }, indent=2)
    except Exception as e:
        return json.dumps({"exists": True, "path": path, "error": str(e)}, indent=2)

@mcp.tool()
def process_list(limit: int = 50, sort_by: str = "cpu") -> str:
    """Get active processes sorted by CPU or Memory usage (limit defaults to 50)."""
    sort_flag = "-%cpu" if sort_by.lower() == "cpu" else "-%mem"
    try:
        out = subprocess.check_output(
            ["ps", "aux", f"--sort={sort_flag}"],
            text=True,
        )
        lines = out.splitlines()
        header = lines[0] if lines else ""
        rows = lines[1:limit+1]
        return header + "\n" + "\n".join(rows)
    except Exception as e:
        return f"Error listing processes: {e}"

@mcp.tool()
def listening_ports() -> str:
    """List open listening TCP and UDP sockets with owning process details."""
    try:
        out = subprocess.check_output(["ss", "-tulnp"], text=True)
        return out
    except Exception:
        try:
            out = subprocess.check_output(["netstat", "-tulnp"], text=True)
            return out
        except Exception as e:
            return f"Error listing ports: {e}"

@mcp.tool()
def network_interfaces() -> str:
    """List network interfaces, status, MAC addresses, and assigned IP addresses."""
    try:
        brief = subprocess.check_output(["ip", "-br", "addr", "show"], text=True).strip()
        full = subprocess.check_output(["ip", "addr", "show"], text=True).strip()
        return f"=== Summary ===\n{brief}\n\n=== Detailed ===\n{full}"
    except Exception as e:
        return f"Error: {e}"

@mcp.tool()
def network_routes() -> str:
    """Get kernel routing tables."""
    try:
        routes = subprocess.check_output(["ip", "route", "show"], text=True).strip()
        return routes
    except Exception as e:
        return f"Error: {e}"

@mcp.tool()
def dns_lookup(domain: str, record_type: str = "A") -> str:
    """Perform a DNS query for domain with specified record type (A, AAAA, MX, TXT, etc.)."""
    try:
        out = subprocess.check_output(["dig", "+nocmd", domain, record_type, "+noall", "+answer"], text=True).strip()
        if not out:
            out = subprocess.check_output(["nslookup", domain], text=True).strip()
        return out if out else f"No {record_type} records found for {domain}"
    except Exception as e:
        return f"DNS lookup error: {e}"

@mcp.tool()
def ping_host(host: str, count: int = 4) -> str:
    """Send ICMP ping packets to a target host or IP."""
    try:
        out = subprocess.check_output(["ping", "-c", str(count), "-W", "2", host], text=True).strip()
        return out
    except subprocess.CalledProcessError as e:
        return f"Ping failed with returncode {e.returncode}:\n{e.output}"
    except Exception as e:
        return f"Ping error: {e}"

@mcp.tool()
def service_status(service_name: str) -> str:
    """Check systemd service status and recent journal logs."""
    try:
        out = subprocess.check_output(
            ["systemctl", "status", service_name, "--no-pager", "-n", "30"],
            text=True,
            stderr=subprocess.STDOUT,
        )
        return out
    except subprocess.CalledProcessError as e:
        return e.output
    except Exception as e:
        return f"Error checking service {service_name}: {e}"

@mcp.tool()
def service_action(service_name: str, action: str) -> str:
    """Execute systemctl action on service: start, stop, restart, reload, enable, disable."""
    allowed_actions = {"start", "stop", "restart", "reload", "enable", "disable", "status"}
    act = action.strip().lower()
    if act not in allowed_actions:
        return f"Invalid action: '{action}'. Allowed: {', '.join(sorted(allowed_actions))}"
    try:
        proc = subprocess.run(
            ["systemctl", act, service_name],
            capture_output=True,
            text=True,
            timeout=60,
        )
        status_code = proc.returncode
        return json.dumps({
            "service": service_name,
            "action": act,
            "returncode": status_code,
            "stdout": proc.stdout,
            "stderr": proc.stderr,
            "success": status_code == 0,
        }, indent=2)
    except Exception as e:
        return json.dumps({"error": str(e)}, indent=2)

@mcp.tool()
def environment_info() -> str:
    """Inspect current process environment variables."""
    safe_env = {}
    for k, v in os.environ.items():
        if any(secret in k.lower() for secret in ["key", "secret", "pass", "token", "auth"]):
            safe_env[k] = "***REDACTED***"
        else:
            safe_env[k] = v
    return json.dumps(safe_env, indent=2)

@mcp.tool()
def installed_command(command_name: str) -> str:
    """Check if an executable exists in system PATH and return its path and version."""
    path = shutil.which(command_name)
    if not path:
        return json.dumps({"installed": False, "command": command_name}, indent=2)
    version_out = ""
    for flag in ["--version", "-v", "-V", "version"]:
        try:
            res = subprocess.run([path, flag], capture_output=True, text=True, timeout=5)
            if res.returncode == 0 and res.stdout.strip():
                version_out = res.stdout.strip().splitlines()[0]
                break
        except Exception:
            pass
    return json.dumps({
        "installed": True,
        "command": command_name,
        "path": path,
        "version": version_out,
    }, indent=2)

@mcp.tool()
def open_files(pid: Optional[int] = None, limit: int = 50) -> str:
    """List open files using lsof (optionally filter by PID, default limit 50)."""
    cmd = ["lsof"]
    if pid is not None:
        cmd.extend(["-p", str(pid)])
    try:
        out = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)
        lines = out.splitlines()
        header = lines[0] if lines else ""
        rows = lines[1:limit+1]
        return header + "\n" + "\n".join(rows)
    except subprocess.CalledProcessError as e:
        return e.output
    except Exception as e:
        return f"Error running lsof: {e}"

# -------------------------------------------------------------
# ASGI Bearer Token Middleware & Application Assembly
# -------------------------------------------------------------

class BearerAuthASGIMiddleware:
    """ASGI Middleware to enforce Bearer Token authentication on all endpoints."""

    def __init__(self, app: Any, token: str):
        self.app = app
        self.token = token

    async def __call__(self, scope: Any, receive: Any, send: Any) -> None:
        if scope["type"] == "http":
            current_token = get_auth_token() or self.token
            headers = dict(scope.get("headers", []))
            auth_val = headers.get(b"authorization", b"").decode("latin1").strip()
            expected = f"Bearer {current_token}"

            # Check query parameters (?token=..., ?api_key=..., ?key=..., ?auth=...)
            query_token = ""
            qs = scope.get("query_string", b"").decode("latin1")
            if qs:
                from urllib.parse import parse_qs
                params = parse_qs(qs)
                for param in ("token", "api_key", "key", "auth"):
                    if param in params and params[param]:
                        query_token = params[param][0]
                        break

            authenticated = False
            if current_token:
                if auth_val == expected or auth_val == current_token:
                    authenticated = True
                elif query_token == current_token:
                    authenticated = True

            if not authenticated:
                err_payload = json.dumps({
                    "jsonrpc": "2.0",
                    "error": {
                        "code": -32001,
                        "message": "Unauthorized: Missing or invalid Bearer token",
                    },
                    "id": None,
                }).encode("utf-8")

                await send({
                    "type": "http.response.start",
                    "status": 401,
                    "headers": [
                        (b"content-type", b"application/json"),
                        (b"content-length", str(len(err_payload)).encode("latin1")),
                        (b"www-authenticate", b"Bearer"),
                    ],
                })
                await send({
                    "type": "http.response.body",
                    "body": err_payload,
                })
                return

        await self.app(scope, receive, send)

def create_app():
    """Build the streamable HTTP Starlette application wrapped with auth middleware."""
    if hasattr(mcp, "streamable_http_app"):
        base_app = mcp.streamable_http_app(
            streamable_http_path="/mcp",
            transport_security=security_settings,
            host="127.0.0.1",
        )
    else:
        base_app = mcp

    final_app = BearerAuthASGIMiddleware(base_app, AUTH_TOKEN)
    return final_app

if __name__ == "__main__":
    import uvicorn
    print(f"Starting CTRLMCP Server on 127.0.0.1:{MCP_PORT} (domain: {MCP_DOMAIN})...")
    app = create_app()
    uvicorn.run(
        app,
        host="127.0.0.1",
        port=MCP_PORT,
        log_level="info",
        access_log=True,
    )
PYEOF

chmod 700 "$SERVER_FILE"
echo -e "${GREEN}  ✓ Server script written and secured at ${SERVER_FILE}.${NC}"

# ==============================================================================
# STEP 6: SYSTEMD SERVICE CONFIGURATION (ctrlmcp.service)
# ==============================================================================
echo -e "${BLUE}[5/8] Creating and enabling systemd service (ctrlmcp.service)...${NC}"

cat << EOF > "$SERVICE_FILE"
[Unit]
Description=CtrlMCP Streamable HTTP Server
Documentation=https://modelcontextprotocol.io/
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$APP_DIR
Environment="MCP_PORT=$MCP_PORT"
Environment="MCP_HTTPS_PORT=$MCP_HTTPS_PORT"
Environment="MCP_DOMAIN=$MCP_DOMAIN"
Environment="MCP_TOKEN_FILE=$TOKEN_FILE"
Environment="PYTHONUNBUFFERED=1"
ExecStart=$VENV_DIR/bin/python $SERVER_FILE
Restart=always
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ctrlmcp.service
systemctl restart ctrlmcp.service

echo -e "${GREEN}  ✓ ctrlmcp.service enabled and started.${NC}"

# STEP 7: NGINX REVERSE PROXY CONFIGURATION
# ==============================================================================
echo -e "${BLUE}[6/8] Configuring Nginx Reverse Proxy with Bearer Auth...${NC}"

rm -f /etc/nginx/sites-enabled/default

# Prepare webroot ACME challenge directory for Certbot
mkdir -p /var/www/html/.well-known/acme-challenge
chmod -R 755 /var/www/html

# Helper function to configure full Nginx reverse proxy with TLS
configure_nginx_site() {
    local CERT_FILE="$1"
    local KEY_FILE="$2"

    local REDIRECT_TARGET
    if [ "$MCP_HTTPS_PORT" = "443" ]; then
        REDIRECT_TARGET="https://\$host\$request_uri"
    else
        REDIRECT_TARGET="https://\$host:${MCP_HTTPS_PORT}\$request_uri"
    fi

    cat << EOF > "$NGINX_AVAILABLE"
server {
    listen 80;
    listen [::]:80;
    server_name $MCP_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location = /install.sh {
        root /var/www/html;
    }

    location / {
        return 301 ${REDIRECT_TARGET};
    }
}

server {
    listen ${MCP_NGINX_PORT} ssl http2;
    listen [::]:${MCP_NGINX_PORT} ssl http2;
    server_name $MCP_DOMAIN;

    ssl_certificate $CERT_FILE;
    ssl_certificate_key $KEY_FILE;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location /mcp {
        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE, PUT' always;
            add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, mcp-session-id, Last-Event-ID, Cache-Control' always;
            add_header 'Access-Control-Max-Age' 86400;
            add_header 'Content-Length' 0;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            return 204;
        }

        set \$auth_ok 0;
        if (\$http_authorization = "Bearer $BEARER_TOKEN") {
            set \$auth_ok 1;
        }
        if (\$arg_token = "$BEARER_TOKEN") {
            set \$auth_ok 1;
        }
        if (\$arg_api_key = "$BEARER_TOKEN") {
            set \$auth_ok 1;
        }
        if (\$arg_key = "$BEARER_TOKEN") {
            set \$auth_ok 1;
        }
        if (\$arg_auth = "$BEARER_TOKEN") {
            set \$auth_ok 1;
        }

        if (\$auth_ok = 0) {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, mcp-session-id, Last-Event-ID, Cache-Control' always;
            return 401 '{"jsonrpc": "2.0", "error": {"code": -32001, "message": "Unauthorized: Invalid or missing Bearer token. Use Authorization header or ?token= query parameter."}, "id": null}\n';
        }

        proxy_pass http://127.0.0.1:$MCP_PORT/mcp;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization "Bearer $BEARER_TOKEN";

        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 50M;

        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE, PUT' always;
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, mcp-session-id, Last-Event-ID, Cache-Control' always;
        add_header 'Access-Control-Expose-Headers' 'mcp-session-id' always;
    }

    location ~ ^/$BEARER_TOKEN(/.*)?$ {
        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE, PUT' always;
            add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, mcp-session-id, Last-Event-ID, Cache-Control' always;
            add_header 'Access-Control-Max-Age' 86400;
            add_header 'Content-Length' 0;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            return 204;
        }

        rewrite ^/$BEARER_TOKEN/(.*)$ /\$1 break;
        rewrite ^/$BEARER_TOKEN$ /mcp break;

        proxy_pass http://127.0.0.1:$MCP_PORT;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Authorization "Bearer $BEARER_TOKEN";

        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding on;

        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 50M;

        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, DELETE, PUT' always;
        add_header 'Access-Control-Allow-Headers' 'Authorization, Content-Type, Accept, mcp-session-id, Last-Event-ID, Cache-Control' always;
        add_header 'Access-Control-Expose-Headers' 'mcp-session-id' always;
    }

    location = /install.sh {
        root /var/www/html;
    }

    location / {
        return 200 "CTRLMCP Server is active for $MCP_DOMAIN.\n";
    }
}
EOF
    ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    nginx -t
    systemctl reload nginx
}

# Initial HTTP port 80 configuration for domain validation and ACME challenges
cat << EOF > "$NGINX_AVAILABLE"
server {
    listen 80;
    listen [::]:80;
    server_name $MCP_DOMAIN;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
        allow all;
    }

    location = /install.sh {
        root /var/www/html;
    }

    location / {
        return 200 "CTRLMCP Server initializing...\n";
    }
}
EOF

ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
nginx -t
systemctl enable nginx
systemctl restart nginx
echo -e "${GREEN}  ✓ Nginx initialized on port 80.${NC}"

# ==============================================================================
# STEP 8: HTTPS VIA LET'S ENCRYPT (CERTBOT)
# ==============================================================================
echo -e "${BLUE}[7/8] Requesting Let's Encrypt SSL certificate for ${MCP_DOMAIN}...${NC}"

# Ensure ports 80 and 443 are open in both UFW and iptables explicitly
if command -v ufw > /dev/null 2>&1; then
    ufw allow 80/tcp > /dev/null 2>&1 || true
    ufw allow 443/tcp > /dev/null 2>&1 || true
    ufw allow "${MCP_HTTPS_PORT}/tcp" > /dev/null 2>&1 || true
fi
iptables -I INPUT 1 -p tcp --dport 80 -j ACCEPT > /dev/null 2>&1 || true
iptables -I INPUT 1 -p tcp --dport 443 -j ACCEPT > /dev/null 2>&1 || true
iptables -I INPUT 1 -p tcp --dport "$MCP_HTTPS_PORT" -j ACCEPT > /dev/null 2>&1 || true
ip6tables -I INPUT 1 -p tcp --dport 80 -j ACCEPT > /dev/null 2>&1 || true
ip6tables -I INPUT 1 -p tcp --dport 443 -j ACCEPT > /dev/null 2>&1 || true
ip6tables -I INPUT 1 -p tcp --dport "$MCP_HTTPS_PORT" -j ACCEPT > /dev/null 2>&1 || true

if command -v netfilter-persistent > /dev/null 2>&1; then
    netfilter-persistent save > /dev/null 2>&1 || true
fi

echo -e "${CYAN}  ℹ️  IMPORTANT: If using Oracle Cloud / AWS / GCP, open port 443 in your Cloud Security List/Group too!${NC}"

CERTBOT_EMAIL_ARGS=()
if [ -n "$LE_EMAIL" ]; then
    CERTBOT_EMAIL_ARGS=(-m "$LE_EMAIL")
else
    CERTBOT_EMAIL_ARGS=(--register-unsafely-without-email)
fi

# Multi-stage Certbot execution: Nginx plugin -> Webroot -> Standalone
echo -e "${BLUE}[*] Stage 1/3: Attempting Certbot Nginx plugin...${NC}"
if ! certbot --nginx --non-interactive --agree-tos --redirect "${CERTBOT_EMAIL_ARGS[@]}" -d "$MCP_DOMAIN"; then
    echo -e "${YELLOW}[*] Stage 2/3: Attempting Webroot ACME challenge...${NC}"
    if ! certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos "${CERTBOT_EMAIL_ARGS[@]}" -d "$MCP_DOMAIN"; then
        echo -e "${YELLOW}[*] Stage 3/3: Attempting Standalone mode (temporary port 80 listener)...${NC}"
        systemctl stop nginx 2>/dev/null || true
        certbot certonly --standalone --non-interactive --agree-tos "${CERTBOT_EMAIL_ARGS[@]}" -d "$MCP_DOMAIN" || true
        systemctl start nginx 2>/dev/null || true
    fi
fi

if [ -f "/etc/letsencrypt/live/$MCP_DOMAIN/fullchain.pem" ]; then
    echo -e "${GREEN}  ✓ Official Let's Encrypt certificate obtained! Configuring HTTPS...${NC}"
    configure_nginx_site "/etc/letsencrypt/live/$MCP_DOMAIN/fullchain.pem" "/etc/letsencrypt/live/$MCP_DOMAIN/privkey.pem"
    echo -e "${GREEN}  ✓ Official Let's Encrypt SSL successfully activated on port ${MCP_NGINX_PORT} (internal) / ${MCP_HTTPS_PORT} (external)!${NC}"
else
    echo -e "${YELLOW}  [WARNING] Certbot was unable to acquire an SSL certificate automatically.${NC}"
    echo -e "${YELLOW}  Possible reason: DNS A-record for '${MCP_DOMAIN}' does not yet resolve to this server IP,${NC}"
    echo -e "${YELLOW}  or Port 80 (HTTP) is blocked in your Cloud Provider's Security List / Ingress Rules.${NC}"
    echo -e "${YELLOW}  Generating self-signed SSL fallback for port ${MCP_HTTPS_PORT} so HTTPS is active immediately...${NC}"
    
    SSL_DIR="/etc/ssl/ctrlmcp"
    mkdir -p "$SSL_DIR"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "$SSL_DIR/fallback.key" \
        -out "$SSL_DIR/fallback.crt" \
        -subj "/CN=$MCP_DOMAIN/O=CTRLMCP Fallback" > /dev/null 2>&1

    configure_nginx_site "$SSL_DIR/fallback.crt" "$SSL_DIR/fallback.key"
    echo -e "${YELLOW}  ⚠️  Fallback SSL configured on port ${MCP_HTTPS_PORT}.${NC}"
    echo -e "${YELLOW}  ℹ️  Claude Web (claude.ai) requires an official certificate. After opening Port 80,${NC}"
    echo -e "${YELLOW}     type 'CTRLMCP' and select Option [5] to upgrade in 3 seconds.${NC}"
fi

# ==============================================================================
# STEP 9: AUTOMATED COMPREHENSIVE VERIFICATION SUITE (12 MANDATORY TESTS)
# ==============================================================================
echo
echo -e "${CYAN}${BOLD}============================================================${NC}"
echo -e "${CYAN}${BOLD}     RUNNING 12-POINT MANDATORY VERIFICATION SUITE         ${NC}"
echo -e "${CYAN}${BOLD}============================================================${NC}"

PASSED_TESTS=0
FAILED_TESTS=0

run_test() {
    local TEST_NUM="$1"
    local TEST_NAME="$2"
    shift 2

    printf "[Test %02d/12] %-48s ... " "$TEST_NUM" "$TEST_NAME"
    if "$@" > /dev/null 2>&1; then
        echo -e "${GREEN}${BOLD}PASSED${NC}"
        PASSED_TESTS=$((PASSED_TESTS + 1))
    else
        echo -e "${RED}${BOLD}FAILED${NC}"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}

sleep 2
MCP_SESSION_ID=""

# 1. Python syntax
test_python_syntax() {
    "$VENV_DIR/bin/python" -m py_compile "$SERVER_FILE"
}
run_test 1 "Python syntax check" test_python_syntax

# 2. Systemd service config validity
test_systemd_valid() {
    systemctl cat ctrlmcp.service
}
run_test 2 "Systemd unit configuration validity" test_systemd_valid

# 3. Systemd service is active (running)
test_systemd_active() {
    systemctl is-active --quiet ctrlmcp.service
}
run_test 3 "Systemd service is active" test_systemd_active

# 4. MCP local endpoint socket connectivity
test_local_socket() {
    curl -s -o /dev/null --connect-timeout 5 "http://127.0.0.1:$MCP_PORT/mcp"
}
run_test 4 "Local MCP endpoint socket connectivity" test_local_socket

# 5. MCP JSON-RPC 'initialize' call & capture session ID
test_mcp_initialize() {
    local resp
    resp=$(curl -s -g -i -X POST "http://127.0.0.1:$MCP_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $BEARER_TOKEN" \
        -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}')
    MCP_SESSION_ID=$(printf '%s\n' "$resp" | grep -i '^mcp-session-id:' | head -n 1 | awk '{print $2}' | tr -d '\r\n')
    printf '%s\n' "$resp" | grep -q '"jsonrpc"'
}
run_test 5 "MCP JSON-RPC 'initialize' call" test_mcp_initialize

# 6. MCP tools/list verification (checking for run_command)
test_mcp_tools_list() {
    local cmd=(curl -s -g -f -X POST "http://127.0.0.1:$MCP_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $BEARER_TOKEN")
    if [ -n "$MCP_SESSION_ID" ]; then
        cmd+=(-H "mcp-session-id: $MCP_SESSION_ID")
    fi
    cmd+=(-d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}')
    "${cmd[@]}" | grep -q 'run_command'
}
run_test 6 "MCP JSON-RPC 'tools/list' verification" test_mcp_tools_list

# 7. Nginx configuration syntax
test_nginx_syntax() {
    nginx -t
}
run_test 7 "Nginx configuration syntax (nginx -t)" test_nginx_syntax

# 8. HTTPS listener on Nginx internal port (MCP_NGINX_PORT=443)
test_https_listener() {
    curl -k -s -o /dev/null --connect-timeout 5 --resolve "$MCP_DOMAIN:$MCP_NGINX_PORT:127.0.0.1" "https://$MCP_DOMAIN:$MCP_NGINX_PORT/"
}
run_test 8 "HTTPS listener on internal port $MCP_NGINX_PORT (Nginx)" test_https_listener

# 9. Authentication WITHOUT token -> MUST FAIL (HTTP 401)
test_auth_without_token() {
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" --resolve "$MCP_DOMAIN:$MCP_NGINX_PORT:127.0.0.1" -X POST "https://$MCP_DOMAIN:$MCP_NGINX_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -d '{"jsonrpc":"2.0","id":9,"method":"tools/list","params":{}}')
    [ "$code" -eq 401 ]
}
run_test 9 "Auth WITHOUT token rejected (HTTP 401)" test_auth_without_token

# 10. Authentication WITH CORRECT token -> MUST SUCCEED (HTTP 200)
test_auth_with_token() {
    local cmd=(curl -k -s -o /dev/null -w "%{http_code}" --resolve "$MCP_DOMAIN:$MCP_NGINX_PORT:127.0.0.1" -X POST "https://$MCP_DOMAIN:$MCP_NGINX_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $BEARER_TOKEN")
    if [ -n "$MCP_SESSION_ID" ]; then
        cmd+=(-H "mcp-session-id: $MCP_SESSION_ID")
    fi
    cmd+=(-d '{"jsonrpc":"2.0","id":10,"method":"tools/list","params":{}}')
    local code
    code=$("${cmd[@]}")
    [ "$code" -eq 200 ]
}
run_test 10 "Auth WITH CORRECT token accepted (HTTP 200)" test_auth_with_token

# 11. Authentication WITH WRONG token -> MUST FAIL (HTTP 401)
test_auth_wrong_token() {
    local code
    code=$(curl -k -s -o /dev/null -w "%{http_code}" --resolve "$MCP_DOMAIN:$MCP_NGINX_PORT:127.0.0.1" -X POST "https://$MCP_DOMAIN:$MCP_NGINX_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer invalid_fake_token_123" \
        -d '{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{}}')
    [ "$code" -eq 401 ]
}
run_test 11 "Auth WITH WRONG token rejected (HTTP 401)" test_auth_wrong_token

# 12. Public HTTPS MCP Endpoint functional
test_https_endpoint_functional() {
    local cmd=(curl -k -s -g -f --resolve "$MCP_DOMAIN:$MCP_NGINX_PORT:127.0.0.1" -X POST "https://$MCP_DOMAIN:$MCP_NGINX_PORT/mcp" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json, text/event-stream" \
        -H "Authorization: Bearer $BEARER_TOKEN")
    if [ -n "$MCP_SESSION_ID" ]; then
        cmd+=(-H "mcp-session-id: $MCP_SESSION_ID")
    fi
    cmd+=(-d '{"jsonrpc":"2.0","id":12,"method":"tools/list","params":{}}')
    "${cmd[@]}" | grep -q 'run_command'
}
run_test 12 "Public HTTPS MCP Endpoint functional" test_https_endpoint_functional

echo -e "${CYAN}------------------------------------------------------------${NC}"
echo -e "Verification Results: ${GREEN}${BOLD}${PASSED_TESTS} Passed${NC} / ${RED}${BOLD}${FAILED_TESTS} Failed${NC}"


if [ "$FAILED_TESTS" -gt 0 ]; then
    echo -e "${RED}[WARNING] One or more tests failed. Check service logs with: journalctl -u ctrlmcp.service -n 50${NC}"
fi

# ==============================================================================
# EXTERNAL PORT CONNECTIVITY CHECK
# ==============================================================================
echo
echo -e "${BLUE}[*] Checking external port ${MCP_HTTPS_PORT} connectivity from the internet...${NC}"

PUBLIC_IP="$(curl -s4 --connect-timeout 5 https://api.ipify.org 2>/dev/null || echo "")"
EXTERNAL_PORT_OK=false

if [ -n "$PUBLIC_IP" ]; then
    test_url="https://${MCP_DOMAIN}:${MCP_HTTPS_PORT}/mcp"
    if [ "$MCP_HTTPS_PORT" = "443" ] || [ -z "$MCP_HTTPS_PORT" ]; then
        test_url="https://${MCP_DOMAIN}/mcp"
    fi
    ext_code=$(curl -sk --connect-timeout 6 --max-time 8 "$test_url" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
    if echo "$ext_code" | grep -qE "^(200|401|400)"; then
        EXTERNAL_PORT_OK=true
    fi
fi

if [ "$EXTERNAL_PORT_OK" = true ]; then
    echo -e "${GREEN}  ✓ External port ${MCP_HTTPS_PORT} is reachable! MCP is publicly accessible.${NC}"
else
    echo -e "${YELLOW}  ⚠️  External port ${MCP_HTTPS_PORT} is NOT reachable from outside.${NC}"
    echo -e "${YELLOW}     This is usually caused by your Cloud Provider or NAT firewall blocking port ${MCP_HTTPS_PORT}.${NC}"
    echo
    echo -e "${CYAN}  ┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}  │  ACTION REQUIRED: Open port ${MCP_HTTPS_PORT} in your firewall/NAT     │${NC}"
    echo -e "${CYAN}  ├─────────────────────────────────────────────────────────────┤${NC}"
    echo -e "${CYAN}  │  Oracle Cloud (OCI):                                        │${NC}"
    echo -e "${CYAN}  │    Networking → VCN → Security Lists → Add Ingress Rule     │${NC}"
    echo -e "${CYAN}  │    Protocol: TCP | Port: ${MCP_HTTPS_PORT} | Source: 0.0.0.0/0           │${NC}"
    echo -e "${CYAN}  │                                                             │${NC}"
    echo -e "${CYAN}  │  NAT/Port Forward Panel:                                    │${NC}"
    echo -e "${CYAN}  │    Add rule: External ${MCP_HTTPS_PORT} → Internal ${MCP_NGINX_PORT} (TCP)          │${NC}"
    echo -e "${CYAN}  │                                                             │${NC}"
    echo -e "${CYAN}  │  AWS: EC2 → Security Groups → Inbound Rules → Add TCP ${MCP_HTTPS_PORT}  │${NC}"
    echo -e "${CYAN}  │  GCP: VPC → Firewall → Add Rule → TCP ${MCP_HTTPS_PORT}               │${NC}"
    echo -e "${CYAN}  └─────────────────────────────────────────────────────────────┘${NC}"
    echo
    echo -e "${YELLOW}  After opening the port, test with:${NC}"
    echo -e "${BOLD}    curl -sk ${test_url} -H 'Authorization: Bearer $(cat /etc/ctrlmcp/token)'${NC}"
fi



# ==============================================================================
# STEP 10: INSTALL CLI TOOL (ctrlmcp / CtrlMCP / CTRLMCP)
# ==============================================================================
cat << 'CLI_EOF' > /usr/local/bin/ctrlmcp
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
        echo -e "  ${RED}${BOLD}[0]${NC} 🚪 Exit (خروج)"
        echo -e "${CYAN}------------------------------------------------------------${NC}"
        
        local CHOICE=""
        if ! read_input "Choose an option [0-6]: " CHOICE; then
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
            0|q|Q|exit)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid choice: '${CHOICE}'. Please choose 0 to 6.${NC}"
                sleep 1
                ;;
        esac
    done
}

load_env
ACTION="${1:-menu}"
ACTION=$(printf '%s' "$ACTION" | tr '[:upper:]' '[:lower:]')

case "$ACTION" in
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
CLI_EOF

chmod +x /usr/local/bin/ctrlmcp
# Create case-insensitive symlinks for CTRLMCP and variants
for alias_cmd in CTRLMCP CtrlMCP Ctrlmcp mcp; do
    if [ "$alias_cmd" != "ctrlmcp" ]; then
        ln -sfn /usr/local/bin/ctrlmcp "/usr/local/bin/$alias_cmd" 2>/dev/null || true
    fi
done

# Install profile hook for arbitrary case variations (e.g. cTrLmCp)
cat << 'PROFILE_EOF' > /etc/profile.d/ctrlmcp.sh
# Catch any case variation of ctrlmcp in interactive shells
command_not_found_handle() {
    local cmd_lower
    cmd_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    if [ "$cmd_lower" = "ctrlmcp" ]; then
        shift
        exec /usr/local/bin/ctrlmcp "$@"
    fi
    if [ -x /usr/lib/command-not-found ]; then
        /usr/lib/command-not-found -- "$1"
        return $?
    elif [ -x /usr/share/command-not-found/command-not-found ]; then
        /usr/share/command-not-found/command-not-found -- "$1"
        return $?
    else
        printf "%s: command not found\n" "$1" >&2
        return 127
    fi
}
PROFILE_EOF
chmod +x /etc/profile.d/ctrlmcp.sh
grep -q 'ctrlmcp' /etc/bash.bashrc 2>/dev/null || cat /etc/profile.d/ctrlmcp.sh >> /etc/bash.bashrc

# ==============================================================================
# STEP 11: DEPLOYMENT COMPLETE & CLIENT CONFIGURATION
# ==============================================================================
echo
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "${GREEN}${BOLD}        CTRLMCP SERVER DEPLOYMENT COMPLETED!               ${NC}"
echo -e "${GREEN}${BOLD}============================================================${NC}"
echo -e "Endpoint URL : ${CYAN}${BOLD}${MCP_ENDPOINT}${NC}"
echo -e "Bearer Token : ${YELLOW}${BOLD}${BEARER_TOKEN}${NC}"
echo -e "Direct URL   : ${CYAN}${BOLD}${MCP_URL_TOKEN}${NC}"
echo -e "Token File   : ${BOLD}/etc/ctrlmcp/token${NC} (Permissions: 600 root-only)"
echo -e "Systemd Unit : ${BOLD}ctrlmcp.service${NC} (Active & Enabled)"
if [ "$MCP_HTTPS_PORT" != "443" ]; then
    echo -e "External Port: ${CYAN}${BOLD}${MCP_HTTPS_PORT}${NC}"
fi
echo
echo -e "${BOLD}Management Command (Type anytime in terminal):${NC}"
echo -e "  - Type ${CYAN}${BOLD}CTRLMCP${NC} or ${CYAN}${BOLD}ctrlmcp${NC} to view this dashboard anytime!"
echo -e "  - ${CYAN}ctrlmcp status${NC}  : Check service status"
echo -e "  - ${CYAN}ctrlmcp restart${NC} : Restart service"
echo -e "  - ${CYAN}ctrlmcp logs${NC}    : View live logs"
echo
echo -e "${BOLD}Client Configuration Example (e.g. Claude Desktop / Cursor):${NC}"
cat << EOF
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
EOF
echo -e "${GREEN}============================================================${NC}"

# Auto-launch interactive CTRLMCP dashboard
echo
echo -e "${CYAN}${BOLD}[*] Launching CTRLMCP interactive dashboard...${NC}"
sleep 1

if [ -t 0 ]; then
    exec /usr/local/bin/ctrlmcp
elif [ -c /dev/tty ] && { true < /dev/tty; } 2>/dev/null; then
    exec /usr/local/bin/ctrlmcp < /dev/tty > /dev/tty 2>&1
else
    /usr/local/bin/ctrlmcp info || true
fi
