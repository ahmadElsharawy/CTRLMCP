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
