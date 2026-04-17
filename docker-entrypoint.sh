#!/bin/bash
set -e

# ==============================================================================
# DeckXHub — Unified Docker Entrypoint
# ==============================================================================
# INSTALL_MODE controls which components start:
#   clawdeckx   — OpenClaw Gateway + ClawDeckX only
#   hermesdeckx — HermesAgent Gateway + HermesDeckX only
#   both        — All four components (default)
# ==============================================================================

INSTALL_MODE="${INSTALL_MODE:-both}"
echo "======================================================================"
echo "  DeckXHub Docker — mode: ${INSTALL_MODE}"
echo "======================================================================"

# --- Helper: write bootstrap status file ---
write_bootstrap() {
    local product="$1" key="$2" value="$3"
    local dir="/data/${product}/bootstrap"
    mkdir -p "$dir"
    echo "$value" > "$dir/$key"
}

# --- Ensure data directories ---
ensure_dirs() {
    mkdir -p /data/clawdeckx /data/openclaw/npm /data/openclaw/state \
             /data/openclaw/logs /data/openclaw/home /data/openclaw/bootstrap \
             /data/hermesdeckx /data/hermesagent/state /data/hermesagent/logs \
             /data/hermesagent/home /data/hermesagent/bootstrap \
             /data/runtime/clawdeckx /data/runtime/openclaw \
             /data/runtime/hermesdeckx /data/runtime/hermesagent
}
ensure_dirs

# ==============================================================================
# OpenClaw Gateway (for ClawDeckX)
# ==============================================================================
start_openclaw_gateway() {
    echo "[DeckXHub] Starting OpenClaw Gateway..."

    # Runtime overlay: prefer updated binary from persistent volume
    if [ -f /data/runtime/openclaw/openclaw.mjs ]; then
        echo "[DeckXHub] Using runtime overlay OpenClaw binary"
        export OPENCLAW_BIN=/data/runtime/openclaw/openclaw.mjs
    else
        export OPENCLAW_BIN=/usr/local/bin/openclaw
    fi

    # Ensure default config if none exists
    local config_path="${OPENCLAW_CONFIG_PATH:-/data/openclaw/state/openclaw.json}"
    if [ ! -f "$config_path" ]; then
        echo "[DeckXHub] Creating default OpenClaw config at $config_path"
        mkdir -p "$(dirname "$config_path")"
        cat > "$config_path" << 'OCJSON'
{
  "gateway": {
    "port": 18789,
    "auth": {
      "token": ""
    }
  }
}
OCJSON
    fi

    export OPENCLAW_CONFIG_PATH="$config_path"
    local gw_port="${OCD_OPENCLAW_GATEWAY_PORT:-18789}"
    local gw_log="${OCD_GATEWAY_LOG:-/data/openclaw/logs/gateway.log}"

    write_bootstrap "openclaw" "status" "starting"

    # Start gateway in background
    nohup "$OPENCLAW_BIN" gateway run \
        --port "$gw_port" \
        >> "$gw_log" 2>&1 &
    local gw_pid=$!
    echo "[DeckXHub] OpenClaw Gateway started (PID $gw_pid, port $gw_port)"

    # Wait for gateway to be ready (max 120s)
    local waited=0
    while [ $waited -lt 120 ]; do
        if curl -sf "http://localhost:${gw_port}/api/v1/health" >/dev/null 2>&1 || \
           curl -sf "http://127.0.0.1:${gw_port}/" >/dev/null 2>&1; then
            echo "[DeckXHub] OpenClaw Gateway ready (${waited}s)"
            write_bootstrap "openclaw" "status" "running"
            write_bootstrap "openclaw" "pid" "$gw_pid"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo "[DeckXHub] WARNING: OpenClaw Gateway did not become ready within 120s"
    write_bootstrap "openclaw" "status" "timeout"
    # Don't exit — let ClawDeckX start anyway, it can retry
}

# ==============================================================================
# HermesAgent Gateway (for HermesDeckX)
# ==============================================================================
start_hermesagent_gateway() {
    echo "[DeckXHub] Starting HermesAgent Gateway..."

    # Runtime overlay
    if [ -f /data/runtime/hermesagent/hermes ]; then
        echo "[DeckXHub] Using runtime overlay HermesAgent binary"
        export HERMES_BIN=/data/runtime/hermesagent/hermes
    else
        export HERMES_BIN=/opt/hermesagent/venv/bin/hermes
    fi

    # Ensure .env exists
    local hermes_home="${HERMES_HOME:-/data/hermesagent/home}"
    mkdir -p "$hermes_home"
    if [ ! -f "$hermes_home/.env" ]; then
        echo "[DeckXHub] Creating default HermesAgent .env"
        touch "$hermes_home/.env"
    fi

    # Ensure config.yaml exists
    if [ ! -f "$hermes_home/config.yaml" ]; then
        echo "[DeckXHub] Creating default HermesAgent config.yaml"
        cat > "$hermes_home/config.yaml" << 'HACFG'
# HermesAgent Configuration
gateway:
  enabled: true
  port: 8642
HACFG
    fi

    local api_port="${OHD_HERMESAGENT_API_PORT:-8642}"
    local gw_log="${OHD_GATEWAY_LOG:-/data/hermesagent/logs/gateway.log}"

    write_bootstrap "hermesagent" "status" "starting"

    # Activate venv and start
    export VIRTUAL_ENV=/opt/hermesagent/venv
    export PATH="$VIRTUAL_ENV/bin:$PATH"
    export HERMES_HOME="$hermes_home"

    nohup "$HERMES_BIN" gateway run \
        >> "$gw_log" 2>&1 &
    local gw_pid=$!
    echo "[DeckXHub] HermesAgent Gateway started (PID $gw_pid, port $api_port)"

    # Wait for gateway (max 120s)
    local waited=0
    while [ $waited -lt 120 ]; do
        if curl -sf "http://localhost:${api_port}/health" >/dev/null 2>&1 || \
           curl -sf "http://127.0.0.1:${api_port}/" >/dev/null 2>&1; then
            echo "[DeckXHub] HermesAgent Gateway ready (${waited}s)"
            write_bootstrap "hermesagent" "status" "running"
            write_bootstrap "hermesagent" "pid" "$gw_pid"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done

    echo "[DeckXHub] WARNING: HermesAgent Gateway did not become ready within 120s"
    write_bootstrap "hermesagent" "status" "timeout"
}

# ==============================================================================
# Start ClawDeckX
# ==============================================================================
start_clawdeckx() {
    echo "[DeckXHub] Starting ClawDeckX..."

    # Runtime overlay
    local bin="/app/clawdeckx"
    if [ -f /data/runtime/clawdeckx/clawdeckx ]; then
        bin="/data/runtime/clawdeckx/clawdeckx"
        chmod +x "$bin"
        echo "[DeckXHub] Using runtime overlay ClawDeckX binary"
    fi

    local port="${OCD_PORT:-18788}"
    local bind="${OCD_BIND:-0.0.0.0}"

    write_bootstrap "clawdeckx" "status" "starting"

    "$bin" \
        --port "$port" \
        --host "$bind" &
    local pid=$!
    echo "[DeckXHub] ClawDeckX started (PID $pid, port $port)"
    write_bootstrap "clawdeckx" "pid" "$pid"
    write_bootstrap "clawdeckx" "status" "running"

    CLAWDECKX_PID=$pid
}

# ==============================================================================
# Start HermesDeckX
# ==============================================================================
start_hermesdeckx() {
    echo "[DeckXHub] Starting HermesDeckX..."

    # Runtime overlay
    local bin="/app/hermesdeckx"
    if [ -f /data/runtime/hermesdeckx/hermesdeckx ]; then
        bin="/data/runtime/hermesdeckx/hermesdeckx"
        chmod +x "$bin"
        echo "[DeckXHub] Using runtime overlay HermesDeckX binary"
    fi

    local port="${OHD_PORT:-19788}"
    local bind="${OHD_BIND:-0.0.0.0}"

    write_bootstrap "hermesdeckx" "status" "starting"

    "$bin" \
        --port "$port" \
        --host "$bind" &
    local pid=$!
    echo "[DeckXHub] HermesDeckX started (PID $pid, port $port)"
    write_bootstrap "hermesdeckx" "pid" "$pid"
    write_bootstrap "hermesdeckx" "status" "running"

    HERMESDECKX_PID=$pid
}

# ==============================================================================
# Signal handling — graceful shutdown
# ==============================================================================
cleanup() {
    echo "[DeckXHub] Shutting down..."
    # Stop DeckX processes
    [ -n "${CLAWDECKX_PID:-}" ] && kill "$CLAWDECKX_PID" 2>/dev/null || true
    [ -n "${HERMESDECKX_PID:-}" ] && kill "$HERMESDECKX_PID" 2>/dev/null || true
    # Stop gateways
    local pid_file
    for pid_file in /data/openclaw/bootstrap/pid /data/hermesagent/bootstrap/pid; do
        if [ -f "$pid_file" ]; then
            kill "$(cat "$pid_file")" 2>/dev/null || true
        fi
    done
    wait
    echo "[DeckXHub] All processes stopped."
    exit 0
}
trap cleanup SIGTERM SIGINT SIGQUIT

# ==============================================================================
# Main — start components based on INSTALL_MODE
# ==============================================================================
CLAWDECKX_PID=""
HERMESDECKX_PID=""

case "$INSTALL_MODE" in
    clawdeckx)
        start_openclaw_gateway
        start_clawdeckx
        ;;
    hermesdeckx)
        start_hermesagent_gateway
        start_hermesdeckx
        ;;
    both)
        start_openclaw_gateway
        start_hermesagent_gateway
        start_clawdeckx
        start_hermesdeckx
        ;;
    *)
        echo "[DeckXHub] ERROR: Unknown INSTALL_MODE: $INSTALL_MODE"
        echo "[DeckXHub] Valid values: clawdeckx, hermesdeckx, both"
        exit 1
        ;;
esac

echo ""
echo "======================================================================"
echo "  DeckXHub is running — mode: ${INSTALL_MODE}"
if [ "$INSTALL_MODE" = "clawdeckx" ] || [ "$INSTALL_MODE" = "both" ]; then
    echo "    ClawDeckX:    http://0.0.0.0:${OCD_PORT:-18788}"
fi
if [ "$INSTALL_MODE" = "hermesdeckx" ] || [ "$INSTALL_MODE" = "both" ]; then
    echo "    HermesDeckX:  http://0.0.0.0:${OHD_PORT:-19788}"
fi
echo "======================================================================"
echo ""

# Wait for any child process to exit
wait -n 2>/dev/null || wait
echo "[DeckXHub] A process exited unexpectedly. Shutting down..."
cleanup
