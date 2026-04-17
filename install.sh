#!/bin/bash
set -e

# ==============================================================================
# DeckXHub — Unified Docker Manager
# Install & manage ClawDeckX, HermesDeckX, or both via Docker.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/KnowHunters/DeckXHub/main/install.sh | bash
#
# Deploy modes:
#   1) ClawDeckX + OpenClaw         → knowhunters/clawdeckx   (existing image)
#   2) HermesDeckX + HermesAgent    → knowhunters/hermesdeckx  (existing image)
#   3) All four components          → knowhunters/deckxhub     (unified image)
# ==============================================================================

# Save script to temp file for reliable re-exec (curl|bash sets $0 to "bash")
SELF_SCRIPT="${BASH_SOURCE[0]:-}"
if [ -z "$SELF_SCRIPT" ] || [ "$SELF_SCRIPT" = "bash" ] || [ "$SELF_SCRIPT" = "/bin/bash" ] || [ ! -f "$SELF_SCRIPT" ]; then
    SELF_SCRIPT="/tmp/.deckxhub-installer.sh"
    if [ ! -f "$SELF_SCRIPT" ]; then
        curl -fsSL "https://raw.githubusercontent.com/KnowHunters/DeckXHub/main/install.sh" -o "$SELF_SCRIPT" 2>/dev/null || true
    fi
fi

# ==============================================================================
# Colors
# ==============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==============================================================================
# Deploy Profiles
# ==============================================================================
# set_deploy_profile <mode>
#   mode: clawdeckx | hermesdeckx | both
# Sets: DP_NAME, DP_IMAGE, DP_ORIGINAL_IMAGE, DP_CONTAINER,
#        DP_COMPOSE_URL, DP_COMPOSE_URL_CN, DP_COMPOSE_FILE,
#        DP_PROJECT, DP_DEFAULT_HOST_PORTS, DP_INTERNAL_PORTS,
#        DP_HEALTH_PORTS
set_deploy_profile() {
    local mode="$1"
    case "$mode" in
        clawdeckx)
            DP_NAME="ClawDeckX + OpenClaw"
            DP_IMAGE="knowhunters/clawdeckx:latest"
            DP_ORIGINAL_IMAGE="knowhunters/clawdeckx"
            DP_CONTAINER="clawdeckx"
            DP_PROJECT="clawdeckx"
            DP_COMPOSE_URL="https://raw.githubusercontent.com/ClawDeckX/ClawDeckX/main/docker-compose.yml"
            DP_COMPOSE_URL_CN="https://ghfast.top/https://raw.githubusercontent.com/ClawDeckX/ClawDeckX/main/docker-compose.yml"
            DP_COMPOSE_FILE="docker-compose-clawdeckx.yml"
            DP_DEFAULT_HOST_PORTS="18700"
            DP_INTERNAL_PORTS="18788"
            DP_HEALTH_PORTS="18700"
            DP_PORT_LABELS=("ClawDeckX")
            DP_PORT_MAPPINGS=("18700:18788")
            ;;
        hermesdeckx)
            DP_NAME="HermesDeckX + HermesAgent"
            DP_IMAGE="knowhunters/hermesdeckx:latest"
            DP_ORIGINAL_IMAGE="knowhunters/hermesdeckx"
            DP_CONTAINER="hermesdeckx"
            DP_PROJECT="hermesdeckx"
            DP_COMPOSE_URL="https://raw.githubusercontent.com/HermesDeckX/HermesDeckX/main/docker-compose.yml"
            DP_COMPOSE_URL_CN="https://ghfast.top/https://raw.githubusercontent.com/HermesDeckX/HermesDeckX/main/docker-compose.yml"
            DP_COMPOSE_FILE="docker-compose-hermesdeckx.yml"
            DP_DEFAULT_HOST_PORTS="19700"
            DP_INTERNAL_PORTS="19788"
            DP_HEALTH_PORTS="19700"
            DP_PORT_LABELS=("HermesDeckX")
            DP_PORT_MAPPINGS=("19700:19788")
            ;;
        both)
            DP_NAME="DeckXHub (ClawDeckX + HermesDeckX)"
            DP_IMAGE="knowhunters/deckxhub:latest"
            DP_ORIGINAL_IMAGE="knowhunters/deckxhub"
            DP_CONTAINER="deckxhub"
            DP_PROJECT="deckxhub"
            DP_COMPOSE_URL="https://raw.githubusercontent.com/KnowHunters/DeckXHub/main/docker-compose.yml"
            DP_COMPOSE_URL_CN="https://ghfast.top/https://raw.githubusercontent.com/KnowHunters/DeckXHub/main/docker-compose.yml"
            DP_COMPOSE_FILE="docker-compose.yml"
            DP_DEFAULT_HOST_PORTS="18700 19700"
            DP_INTERNAL_PORTS="18788 19788"
            DP_HEALTH_PORTS="18700 19700"
            DP_PORT_LABELS=("ClawDeckX" "HermesDeckX")
            DP_PORT_MAPPINGS=("18700:18788" "19700:19788")
            ;;
        *)
            echo -e "${RED}Unknown mode: $mode${NC}"; exit 1
            ;;
    esac
}

# Docker registry mirrors for China mainland
DOCKER_MIRRORS=(
    "https://docker.1ms.run"
    "https://docker.xuanyuan.me"
)
NEED_MIRROR=false
DOCKER_MIRROR=""
COMPOSE_CMD=""

# ==============================================================================
# Utility Functions
# ==============================================================================

# Print a box row: │  content ...padding... │
# Usage: box_row "visible text" [width]  (default width=57)
# Handles ANSI codes and CJK double-width chars correctly.
box_row() {
    local raw="$1"
    local width="${2:-57}"
    # Strip ANSI escape sequences to get visible text
    local stripped
    stripped=$(echo -e "$raw" | sed 's/\x1b\[[0-9;]*m//g')
    # Calculate visible width using wc -L (handles CJK double-width)
    local vw
    vw=$(echo -n "$stripped" | wc -L 2>/dev/null || echo ${#stripped})
    vw=$((vw + 0))  # ensure numeric
    local pad=$((width - vw))
    [ "$pad" -lt 0 ] && pad=0
    local spaces=""
    for (( j=0; j<pad; j++ )); do spaces+=" "; done
    echo -e "${CYAN}│${NC}${raw}${spaces}${CYAN}│${NC}"
}

sed_inplace() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

check_port_available() {
    local port=$1
    if command -v ss &>/dev/null; then
        if ss -tlnH 2>/dev/null | grep -qE ":${port}\b"; then return 1; fi
        return 0
    fi
    if command -v lsof &>/dev/null; then
        if lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1; then return 1; fi
        return 0
    fi
    if (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null; then return 1; fi
    return 0
}

find_available_port() {
    local start=${1:-18700}
    local port=$start
    local max_attempts=20
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if check_port_available "$port"; then
            FOUND_PORT=$port
            return 0
        fi
        echo -e "${YELLOW}  Port $port is in use / 端口 $port 已被占用${NC}"
        port=$((port + 1))
        attempt=$((attempt + 1))
    done
    FOUND_PORT=$start
    return 1
}

print_access_urls() {
    local port="${1:-18700}"
    local name="${2:-DeckXHub}"
    echo -e "${CYAN}Access $name / 访问 $name：${NC}"
    echo -e "  ${GREEN}http://localhost:${port}${NC}"
    local lan_ips
    lan_ips=$(hostname -I 2>/dev/null || ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' || true)
    for ip in $lan_ips; do
        [ "$ip" = "127.0.0.1" ] && continue
        echo -e "  ${GREEN}http://${ip}:${port}${NC}  (LAN)"
    done
    local pub_ip=""
    pub_ip=$(curl -sf --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null \
          || curl -sf --connect-timeout 3 --max-time 5 https://ifconfig.me 2>/dev/null \
          || curl -sf --connect-timeout 3 --max-time 5 https://ipinfo.io/ip 2>/dev/null \
          || true)
    if [ -n "$pub_ip" ]; then
        echo -e "  ${GREEN}http://${pub_ip}:${port}${NC}  (Public / 公网)"
    fi
    if [ -n "$pub_ip" ] || [ -n "$lan_ips" ]; then
        echo -e "  ${YELLOW}🔒 Remember to open port ${port} in your firewall${NC}"
        echo -e "  ${YELLOW}   请确保防火墙已放行端口 ${port}${NC}"
    fi
}

detect_network() {
    if curl -sf --connect-timeout 3 --max-time 5 "https://registry-1.docker.io/v2/" >/dev/null 2>&1; then return 1; fi
    if curl -sf --connect-timeout 3 --max-time 5 "https://www.google.com" >/dev/null 2>&1; then return 1; fi
    return 0
}

download_with_fallback() {
    local url="$1" cn_url="$2" output="$3"
    if [ "$NEED_MIRROR" = true ] && [ -n "$cn_url" ]; then
        echo -e "${CYAN}Using China proxy... / 使用中国代理...${NC}"
        if curl -fsSL --connect-timeout 10 --max-time 30 "$cn_url" -o "$output" 2>/dev/null; then return 0; fi
        echo -e "${YELLOW}China proxy failed, trying direct... / 中国代理失败，尝试直连...${NC}"
    fi
    curl -fsSL --connect-timeout 15 --max-time 60 "$url" -o "$output"
}

check_docker() {
    local verbose="${1:-}"
    if ! command -v docker &>/dev/null; then return 1; fi
    if ! docker info &>/dev/null; then
        if [ "$verbose" = "verbose" ]; then
            echo -e "${YELLOW}⚠ Docker is installed but the daemon is not running."
            echo -e "  Docker 已安装但守护进程未运行。${NC}"
            if command -v systemctl &>/dev/null; then
                echo -e "${CYAN}Attempting to start Docker... / 正在尝试启动 Docker...${NC}"
                sudo systemctl start docker 2>/dev/null; sleep 2
                if docker info &>/dev/null; then
                    echo -e "${GREEN}✓ Docker started / Docker 已启动${NC}"; return 0
                fi
            fi
            echo -e "${YELLOW}Please start Docker manually: sudo systemctl start docker${NC}"
        fi
        return 2
    fi
    return 0
}

check_docker_compose() {
    if docker compose version &>/dev/null; then COMPOSE_CMD="docker compose"; return 0; fi
    if command -v docker-compose &>/dev/null; then COMPOSE_CMD="docker-compose"; return 0; fi
    return 1
}

install_docker_engine() {
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Install Docker / 安装 Docker${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Docker is not installed. Installing via official script..."
    echo -e "未检测到 Docker，正在通过官方脚本安装...${NC}"
    echo ""
    local install_ok=false
    if [ "$NEED_MIRROR" = true ]; then
        echo -e "${CYAN}Using Aliyun mirror for Docker installation..."
        echo -e "使用阿里云镜像安装 Docker...${NC}"
        if curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun; then install_ok=true; fi
    fi
    if [ "$install_ok" = false ]; then
        if ! curl -fsSL https://get.docker.com | sh; then
            echo -e "${RED}✗ Docker installation failed / Docker 安装失败${NC}"
            echo -e "${YELLOW}Please install Docker manually: https://docs.docker.com/engine/install/${NC}"
            return 1
        fi
    fi
    echo -e "${GREEN}✓ Docker installed successfully / Docker 安装成功${NC}"
    if command -v systemctl &>/dev/null; then
        sudo systemctl start docker 2>/dev/null || true
        sudo systemctl enable docker 2>/dev/null || true
    fi
    local current_user; current_user=$(whoami)
    if [ "$current_user" != "root" ]; then
        sudo usermod -aG docker "$current_user" 2>/dev/null || true
        if ! docker info &>/dev/null 2>&1; then sg docker -c "true" 2>/dev/null || true; fi
        if ! docker info &>/dev/null 2>&1; then
            echo -e "${YELLOW}⚠ Docker group not yet effective in this session."
            echo -e "  Will use sudo for docker commands in this session."
            echo -e "  Docker 组在当前会话未生效，本次将使用 sudo 执行 docker 命令。${NC}"
        fi
    fi
    return 0
}

configure_docker_mirror() {
    local daemon_json="/etc/docker/daemon.json"
    echo -e "${CYAN}Configuring Docker registry mirrors for faster pulls..."
    echo -e "正在配置 Docker 镜像加速器以加快拉取速度...${NC}"
    local mirrors_json=""
    for m in "${DOCKER_MIRRORS[@]}"; do
        if [ -n "$mirrors_json" ]; then mirrors_json="$mirrors_json, "; fi
        mirrors_json="$mirrors_json\"$m\""
    done
    sudo mkdir -p /etc/docker
    if [ -f "$daemon_json" ]; then
        if grep -q "registry-mirrors" "$daemon_json" 2>/dev/null; then
            echo -e "${YELLOW}Docker mirrors already configured in $daemon_json${NC}"; return 0
        fi
        local tmp_json; tmp_json=$(mktemp)
        sed '$ s/}$//' "$daemon_json" > "$tmp_json"
        echo "  ,\"registry-mirrors\": [$mirrors_json]" >> "$tmp_json"
        echo "}" >> "$tmp_json"
        sudo cp "$tmp_json" "$daemon_json"; rm -f "$tmp_json"
    else
        sudo tee "$daemon_json" > /dev/null << EOF
{
  "registry-mirrors": [$mirrors_json]
}
EOF
    fi
    echo -e "${GREEN}✓ Docker registry mirrors configured / Docker 镜像加速器已配置${NC}"
    if command -v systemctl &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
        echo -e "${CYAN}Restarting Docker... / 正在重启 Docker...${NC}"
        sudo systemctl restart docker 2>/dev/null || true; sleep 2
    fi
}

apply_image_mirror() {
    local compose_file="$1" original_image="$2"
    if [ "$NEED_MIRROR" != true ] || [ -z "$DOCKER_MIRROR" ]; then return; fi
    local mirror_host; mirror_host=$(echo "$DOCKER_MIRROR" | sed 's|https\?://||')
    local mirrored_image="${mirror_host}/${original_image}"
    if grep -q "$mirrored_image" "$compose_file" 2>/dev/null; then return; fi
    sed_inplace "s|image: ${original_image}|image: ${mirrored_image}|" "$compose_file"
    echo -e "${GREEN}✓ Using mirror: ${mirrored_image}${NC}"
}

revert_image_mirror() {
    local compose_file="$1" original_image="$2"
    if [ -z "$DOCKER_MIRROR" ]; then return; fi
    local mirror_host; mirror_host=$(echo "$DOCKER_MIRROR" | sed 's|https\?://||')
    local mirrored_image="${mirror_host}/${original_image}"
    if grep -q "$mirrored_image" "$compose_file" 2>/dev/null; then
        sed_inplace "s|image: ${mirrored_image}|image: ${original_image}|" "$compose_file"
    fi
}

# ==============================================================================
# Detect existing Docker deployments
# ==============================================================================
# Scans for running/stopped containers and compose files (including custom-named)
detect_deployments() {
    DETECTED_DEPLOYMENTS=()
    DETECTED_COMPOSE_FILES=()

    # Check Docker containers (running + stopped) matching our images
    if check_docker 2>/dev/null; then
        local all_containers
        all_containers=$(docker ps -a --format '{{.Names}}' 2>/dev/null || true)
        for cname in $all_containers; do
            local cimg
            cimg=$(docker inspect --format='{{.Config.Image}}' "$cname" 2>/dev/null || true)
            case "$cimg" in
                *knowhunters/clawdeckx*|*knowhunters/hermesdeckx*|*knowhunters/deckxhub*)
                    DETECTED_DEPLOYMENTS+=("$cname")
                    ;;
            esac
        done
    fi

    # Check local compose files (default + custom-named)
    for cf in docker-compose.yml docker-compose-clawdeckx.yml docker-compose-hermesdeckx.yml docker-compose-*.yml; do
        if [ -f "$cf" ]; then
            # Avoid duplicates
            local dup=false
            for existing in "${DETECTED_COMPOSE_FILES[@]}"; do
                if [ "$existing" = "$cf" ]; then dup=true; break; fi
            done
            if [ "$dup" = false ]; then
                DETECTED_COMPOSE_FILES+=("$cf")
            fi
        fi
    done
}

# ==============================================================================
# Docker Install — prompt for instance name, then call docker_install_core
# ==============================================================================
docker_install() {
    local mode="$1"
    set_deploy_profile "$mode"

    # Auto-detect next available instance name
    local default_name="$DP_CONTAINER"
    if [ -f "$DP_COMPOSE_FILE" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$default_name"; then
        local n=2
        while [ -f "docker-compose-${default_name}-${n}.yml" ] || docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${default_name}-${n}"; do
            n=$((n + 1))
        done
        default_name="${DP_CONTAINER}-${n}"
    fi

    echo ""
    echo -e "${CYAN}Each deployment needs a unique instance name."
    echo -e "每个部署需要一个唯一的实例名称。${NC}"
    echo ""
    echo -e "Suggested: ${GREEN}${default_name}${NC}"
    echo -e "Examples: ${DP_CONTAINER}-2, ${DP_CONTAINER}-dev, ${DP_CONTAINER}-test"
    echo ""
    echo -n "Instance name / 实例名称 [${default_name}]: "
    read -r INSTANCE_NAME </dev/tty
    INSTANCE_NAME="${INSTANCE_NAME:-$default_name}"
    # Sanitize: lowercase, replace spaces with hyphens, remove invalid chars
    INSTANCE_NAME=$(echo "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9_-]//g')
    if [ -z "$INSTANCE_NAME" ]; then INSTANCE_NAME="$default_name"; fi

    # Check if this instance name is already in use
    local check_file="$DP_COMPOSE_FILE"
    if [ "$INSTANCE_NAME" != "$DP_CONTAINER" ]; then
        check_file="docker-compose-${INSTANCE_NAME}.yml"
    fi
    if [ -f "$check_file" ]; then
        echo -e "${YELLOW}⚠ Instance '$INSTANCE_NAME' already exists ($check_file)."
        echo -e "  实例 '$INSTANCE_NAME' 已存在 ($check_file)${NC}"
        echo -n "Continue anyway? (will overwrite) / 继续？（将覆盖） [y/N] "
        read -n 1 -r </dev/tty; echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then return 1; fi
    fi

    docker_install_core "$mode" "$INSTANCE_NAME"
}

# ==============================================================================
# Docker Install Core — performs the actual deployment
# ==============================================================================
docker_install_core() {
    local mode="$1"
    local instance_name="${2:-$DP_CONTAINER}"
    set_deploy_profile "$mode"

    local compose_file="$DP_COMPOSE_FILE"
    if [ "$instance_name" != "$DP_CONTAINER" ]; then
        compose_file="docker-compose-${instance_name}.yml"
    fi

    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Deploy: ${DP_NAME}${NC}"
    echo -e "${YELLOW}  Image:  ${DP_IMAGE}${NC}"
    if [ "$instance_name" != "$DP_CONTAINER" ]; then
        echo -e "${YELLOW}  Instance / 实例: ${instance_name}${NC}"
    fi
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Network detection
    echo -e "${CYAN}Checking network connectivity... / 正在检测网络连通性...${NC}"
    if detect_network; then
        NEED_MIRROR=true; DOCKER_MIRROR="${DOCKER_MIRRORS[0]}"
        echo ""
        echo -e "${YELLOW}┌─────────────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  ⚠  ACCELERATED DOWNLOAD MODE / 加速下载模式已启用      │${NC}"
        echo -e "${YELLOW}├─────────────────────────────────────────────────────────┤${NC}"
        echo -e "${YELLOW}│  Mirror / 镜像站: ${CYAN}${DOCKER_MIRROR}${YELLOW}              │${NC}"
        echo -e "${YELLOW}│  GitHub Proxy / 代理: ${CYAN}ghfast.top${YELLOW}                       │${NC}"
        echo -e "${YELLOW}└─────────────────────────────────────────────────────────┘${NC}"
    else
        echo -e "${GREEN}✓ Direct network access OK / 网络直连正常${NC}"
    fi
    echo ""

    # Ensure Docker is installed and running
    if ! check_docker verbose; then
        echo -n "Docker not installed. Install now? / 未安装 Docker，立即安装？ [Y/n] "
        read -n 1 -r </dev/tty; echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then echo -e "${RED}Aborted.${NC}"; exit 1; fi
        if ! install_docker_engine; then exit 1; fi
        echo ""
    fi
    if ! check_docker_compose; then
        echo -e "${RED}✗ docker compose not found. Please install Docker Compose.${NC}"; exit 1
    fi
    echo -e "${GREEN}✓ Docker is ready${NC}"
    echo -e "${GREEN}✓ Compose: $COMPOSE_CMD${NC}"
    echo ""

    # Configure mirror if needed
    if [ "$NEED_MIRROR" = true ]; then configure_docker_mirror; echo ""; fi

    # Check for existing container with same name
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$instance_name"; then
        echo -e "${YELLOW}⚠ Container '${instance_name}' already exists.${NC}"
        echo -n "Stop and recreate? / 停止并重建？ [Y/n] "
        read -n 1 -r </dev/tty; echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then echo -e "${YELLOW}Aborted.${NC}"; exit 0; fi
        if [ -f "$compose_file" ] && check_docker_compose; then
            $COMPOSE_CMD -f "$compose_file" -p "$instance_name" down 2>/dev/null || true
        else
            docker stop "$instance_name" 2>/dev/null || true
            docker rm "$instance_name" 2>/dev/null || true
        fi
        echo ""
    fi

    # Download docker-compose.yml from the appropriate project
    echo -e "${CYAN}Downloading docker-compose.yml for ${DP_NAME}...${NC}"
    download_with_fallback "$DP_COMPOSE_URL" "$DP_COMPOSE_URL_CN" "$compose_file"
    echo -e "${GREEN}✓ Downloaded: ${compose_file}${NC}"

    # Customize compose file for non-default instance (unique names for isolation)
    if [ "$instance_name" != "$DP_CONTAINER" ]; then
        echo -e "${CYAN}Customizing for instance '$instance_name'... / 正在为实例 '$instance_name' 定制配置...${NC}"
        sed_inplace "s/container_name: ${DP_CONTAINER}/container_name: ${instance_name}/" "$compose_file"
        # Rename volumes and network for isolation
        sed_inplace "s/name: ${DP_CONTAINER}-/name: ${instance_name}-/g" "$compose_file"
        sed_inplace "s/name: ${DP_PROJECT}-net/name: ${instance_name}-net/" "$compose_file"
        echo -e "${GREEN}✓ Configured for instance: $instance_name${NC}"
    fi

    # Port configuration — interactive
    echo ""
    echo -e "${CYAN}═══ Port Configuration / 端口配置 ═══${NC}"
    local host_ports=()
    local idx=0
    # Collect ports already assigned by other Docker instances
    local assigned_ports=()
    for _cf in docker-compose.yml docker-compose-*.yml; do
        [ -f "$_cf" ] || continue
        [ "$_cf" = "$compose_file" ] && continue
        for _internal in ${DP_INTERNAL_PORTS}; do
            local _ap
            _ap=$(grep -oE "\"[0-9]+:${_internal}\"" "$_cf" 2>/dev/null | head -1 | grep -oE '^"[0-9]+' | tr -d '"')
            [ -n "$_ap" ] && assigned_ports+=("$_ap")
        done
    done

    for mapping in "${DP_PORT_MAPPINGS[@]}"; do
        local default_host="${mapping%%:*}"
        local container_port="${mapping##*:}"
        local label="${DP_PORT_LABELS[$idx]}"

        find_available_port "$default_host"
        local suggested_port=$FOUND_PORT
        # If found port is assigned to another instance (stopped), bump and retry
        for _used in "${assigned_ports[@]}"; do
            while [ "$suggested_port" = "$_used" ]; do
                find_available_port $((suggested_port + 1))
                suggested_port=$FOUND_PORT
            done
        done

        if [ "$suggested_port" -ne "$default_host" ]; then
            echo -e "${YELLOW}  ⚠ ${label}: default port ${default_host} is occupied${NC}"
            echo -e "${YELLOW}    ${label}: 默认端口 ${default_host} 已被占用${NC}"
        fi

        echo -n "  ${label} port / 端口 [${suggested_port}]: "
        read -r user_port </dev/tty
        user_port="${user_port:-$suggested_port}"

        # Validate port number
        while ! echo "$user_port" | grep -qE '^[0-9]+$' || [ "$user_port" -lt 1 ] || [ "$user_port" -gt 65535 ]; do
            echo -e "${RED}  Invalid port. Enter 1-65535 / 端口无效，请输入 1-65535${NC}"
            echo -n "  ${label} port / 端口 [${suggested_port}]: "
            read -r user_port </dev/tty
            user_port="${user_port:-$suggested_port}"
        done

        # Warn if chosen port is occupied
        if ! check_port_available "$user_port"; then
            echo -e "${YELLOW}  ⚠ Port ${user_port} is in use — container may fail to start${NC}"
            echo -e "${YELLOW}    端口 ${user_port} 已被占用 — 容器可能无法启动${NC}"
        fi

        local chosen_port="$user_port"
        echo -e "${GREEN}  ✓ ${label}: port ${chosen_port}${NC}"

        # Update compose file with chosen port
        if [ "$chosen_port" -ne "$default_host" ]; then
            sed_inplace "s|\"${default_host}:${container_port}\"|\"${chosen_port}:${container_port}\"|" "$compose_file"
        fi

        host_ports+=("$chosen_port")
        assigned_ports+=("$chosen_port")
        idx=$((idx + 1))
    done

    # Configuration confirmation summary
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
    box_row "  Configuration Summary / 配置摘要"
    echo -e "${CYAN}├─────────────────────────────────────────────────────────┤${NC}"
    box_row "  Mode / 模式:     ${BOLD}${DP_NAME}${NC}"
    box_row "  Instance / 实例: ${BOLD}${instance_name}${NC}"
    box_row "  Image / 镜像:    ${BOLD}${DP_IMAGE}${NC}"
    box_row "  Compose file:    ${BOLD}${compose_file}${NC}"
    idx=0
    for hp in "${host_ports[@]}"; do
        local label="${DP_PORT_LABELS[$idx]}"
        box_row "  ${label} port:    ${BOLD}${hp}${NC}"
        idx=$((idx + 1))
    done
    if [ "$NEED_MIRROR" = true ]; then
        box_row "  Mirror / 加速:   ${BOLD}${DOCKER_MIRROR}${NC}"
    fi
    echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -n "Proceed with deployment? / 确认部署？ [Y/n] "
    read -n 1 -r </dev/tty; echo
    if [[ $REPLY =~ ^[Nn]$ ]]; then
        echo -e "${YELLOW}Deployment cancelled / 部署已取消${NC}"
        rm -f "$compose_file"
        return 1
    fi

    # Apply image mirror if needed
    apply_image_mirror "$compose_file" "$DP_ORIGINAL_IMAGE"

    local compose_run="$COMPOSE_CMD -f $compose_file -p $instance_name"

    # Pull image
    echo ""
    echo -e "${BLUE}Pulling Docker image: ${DP_IMAGE}${NC}"
    echo -e "${BLUE}正在拉取 Docker 镜像...${NC}"
    if ! $compose_run pull 2>&1; then
        if [ "$NEED_MIRROR" = true ]; then
            echo -e "${YELLOW}Mirror pull failed, trying direct... / 镜像拉取失败，尝试直连...${NC}"
            revert_image_mirror "$compose_file" "$DP_ORIGINAL_IMAGE"
            if ! $compose_run pull 2>&1; then
                echo -e "${RED}✗ Failed to pull image / 拉取镜像失败${NC}"; exit 1
            fi
        else
            echo -e "${RED}✗ Failed to pull image / 拉取镜像失败${NC}"; exit 1
        fi
    fi
    echo -e "${GREEN}✓ Image pulled / 镜像拉取完成${NC}"

    # Start container
    echo ""
    echo -e "${BLUE}Starting container... / 正在启动容器...${NC}"
    $compose_run up -d

    # Wait for health check
    echo ""
    echo -e "${CYAN}Waiting for services to become ready (first boot may take ~2 min)..."
    echo -e "等待服务就绪（首次启动可能需要约 2 分钟）...${NC}"
    local max_wait=150 waited=0
    while [ $waited -lt $max_wait ]; do
        local any_ok=false
        for hp in "${host_ports[@]}"; do
            if curl -sf "http://localhost:${hp}/api/v1/health" >/dev/null 2>&1; then
                any_ok=true; break
            fi
        done
        if [ "$any_ok" = true ]; then break; fi
        sleep 2; waited=$((waited + 2))
        if [ $((waited % 10)) -eq 0 ]; then printf "\r  %ds / %ds ..." "$waited" "$max_wait"; fi
    done
    printf "\r                          \r"

    if [ $waited -ge $max_wait ]; then
        echo -e "${YELLOW}⚠ Services are still starting. Check status with:"
        echo -e "  服务仍在启动中，请用以下命令检查状态：${NC}"
        echo -e "  ${GREEN}$compose_run ps${NC}"
        echo -e "  ${GREEN}$compose_run logs --tail 30${NC}"
    else
        echo -e "${GREEN}✓ Services are ready! / 服务已就绪！${NC}"
    fi

    # Summary
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  ✅ ${DP_NAME} deployed successfully!${NC}"
    echo -e "${GREEN}  ✅ ${DP_NAME} 部署成功！${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    idx=0
    for hp in "${host_ports[@]}"; do
        local label="${DP_PORT_LABELS[$idx]}"
        print_access_urls "$hp" "$label"
        echo ""
        idx=$((idx + 1))
    done

    # Data volume paths
    local vol_base="/var/lib/docker/volumes"
    echo -e "${CYAN}📂 Data volumes (host path) / 数据卷（宿主机路径）：${NC}"
    local vol_names
    vol_names=$(docker inspect --format '{{ range .Mounts }}{{ .Name }} {{ end }}' "$instance_name" 2>/dev/null || true)
    if [ -n "$vol_names" ]; then
        for vn in $vol_names; do
            echo -e "  ${GREEN}${vol_base}/${vn}/_data${NC}"
        done
    else
        echo -e "  ${GREEN}${vol_base}/${instance_name}-data/_data${NC}"
    fi
    echo ""

    # First-time login credentials (read from container bootstrap files)
    echo -e "${YELLOW}🔐 Initial Login Credentials / 初始登录凭据：${NC}"
    echo ""
    local _cred_shown=false
    for _product in clawdeckx hermesdeckx; do
        local _cred
        _cred=$(docker exec "$instance_name" cat "/data/${_product}/bootstrap/credentials" 2>/dev/null || true)
        if [ -n "$_cred" ]; then
            local _user _pass _label
            _user=$(echo "$_cred" | sed -n '1p')
            _pass=$(echo "$_cred" | sed -n '2p')
            case "$_product" in
                clawdeckx)   _label="ClawDeckX" ;;
                hermesdeckx) _label="HermesDeckX" ;;
            esac
            echo -e "  ${CYAN}${_label}:${NC}"
            echo -e "    Username / 用户名:  ${BOLD}${_user}${NC}"
            echo -e "    Password / 密码:    ${BOLD}${_pass}${NC}"
            echo ""
            _cred_shown=true
        fi
    done
    if [ "$_cred_shown" = false ]; then
        echo -e "  ${YELLOW}Credentials not found. Check container logs:${NC}"
        echo -e "  ${YELLOW}未找到凭据，请查看容器日志：${NC}"
        echo -e "  ${GREEN}$compose_run logs --tail 50${NC}"
        echo ""
    else
        echo -e "  ${YELLOW}⚠ Please change the default password after first login!${NC}"
        echo -e "  ${YELLOW}⚠ 请在首次登录后修改默认密码！${NC}"
        echo ""
    fi

    # Management commands
    echo -e "${YELLOW}Management commands / 管理命令：${NC}"
    echo -e "  ${GREEN}$compose_run ps${NC}              — Status / 状态"
    echo -e "  ${GREEN}$compose_run logs --tail 50${NC}  — Logs / 日志"
    echo -e "  ${GREEN}$compose_run restart${NC}         — Restart / 重启"
    echo -e "  ${GREEN}$compose_run stop${NC}            — Stop / 停止"
    echo -e "  ${GREEN}$compose_run down${NC}            — Remove / 删除容器"
    echo -e "  ${GREEN}$compose_run pull && $compose_run up -d${NC} — Update / 更新"
    echo ""
    exit 0
}

# ==============================================================================
# Management menu for existing deployments
# ==============================================================================
manage_deployment() {
    local container="$1"

    # Find matching compose file (try exact name, then scan compose files)
    local compose_file="" project=""
    case "$container" in
        clawdeckx)   compose_file="docker-compose-clawdeckx.yml"; project="clawdeckx" ;;
        hermesdeckx) compose_file="docker-compose-hermesdeckx.yml"; project="hermesdeckx" ;;
        deckxhub)    compose_file="docker-compose.yml"; project="deckxhub" ;;
    esac
    # Fallback: try docker-compose-{name}.yml for custom instances
    if [ -z "$compose_file" ] || [ ! -f "$compose_file" ]; then
        if [ -f "docker-compose-${container}.yml" ]; then
            compose_file="docker-compose-${container}.yml"
            project="$container"
        fi
    fi
    # Fallback: scan all compose files for this container name
    if [ -z "$compose_file" ] || [ ! -f "$compose_file" ]; then
        for _cf in docker-compose.yml docker-compose-*.yml; do
            [ -f "$_cf" ] || continue
            if grep -q "container_name: ${container}" "$_cf" 2>/dev/null; then
                compose_file="$_cf"
                project="$container"
                break
            fi
        done
    fi

    if [ -z "$compose_file" ] || [ ! -f "$compose_file" ]; then
        echo -e "${YELLOW}No compose file found for ${container}. Using docker commands directly.${NC}"
        compose_file=""
    fi

    # Gather container info
    local is_running=false
    if docker ps --filter "name=^${container}$" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q .; then
        is_running=true
    fi
    local docker_ver
    docker_ver=$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$container" 2>/dev/null || echo "unknown")
    [ "$docker_ver" = "<no value>" ] && docker_ver="unknown"
    local docker_img
    docker_img=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "unknown")

    # Read port(s) from compose file, fallback to Docker inspect
    local compose_ports=""
    if [ -n "$compose_file" ] && [ -f "$compose_file" ]; then
        compose_ports=$(grep -oE '"[0-9]+:[0-9]+"' "$compose_file" 2>/dev/null | tr -d '"' | tr '\n' ' ')
    fi
    if [ -z "$compose_ports" ]; then
        compose_ports=$(docker port "$container" 2>/dev/null | sed 's|.*:||; s|/.*||' | sort -u | tr '\n' ' ')
    fi

    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Manage: ${BOLD}${container}${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}Compose file / 配置文件：${NC} ${compose_file:-N/A}"
    echo -e "${CYAN}Image / 镜像：${NC}          $docker_img"
    echo -e "${CYAN}Version / 版本：${NC}        $docker_ver"
    echo -e "${CYAN}Port(s) / 端口：${NC}        ${compose_ports:-N/A}"
    if [ "$is_running" = true ]; then
        echo -e "${CYAN}Status / 状态：${NC}         ${GREEN}Running / 运行中${NC}"
    else
        echo -e "${CYAN}Status / 状态：${NC}         ${YELLOW}Stopped / 已停止${NC}"
    fi
    echo ""
    echo -e "${YELLOW}What would you like to do? / 您想做什么？${NC}"
    echo "  1) Update / 更新"
    if [ "$is_running" = true ]; then
        echo "  2) Stop / 停止"
    else
        echo "  2) Start / 启动"
    fi
    echo "  3) Restart / 重启"
    echo "  4) Logs / 查看日志"
    echo "  5) Status / 查看状态"
    echo "  6) Uninstall / 卸载"
    echo "  7) Back / 返回"
    echo ""
    echo -n "Choice / 选择 [1-7]: "
    read -n 1 -r MGMT_CHOICE </dev/tty; echo

    if [ -n "$compose_file" ] && [ -f "$compose_file" ] && check_docker_compose; then
        local cr="$COMPOSE_CMD -f $compose_file -p $project"
        case "$MGMT_CHOICE" in
            1)
                # Update
                echo ""
                echo -e "${CYAN}Checking network connectivity... / 正在检测网络连通性...${NC}"
                if detect_network; then
                    NEED_MIRROR=true; DOCKER_MIRROR="${DOCKER_MIRRORS[0]}"
                    echo -e "${YELLOW}⚠ Using mirror / 已启用加速${NC}"
                    configure_docker_mirror
                    # Try to figure out original image for mirror
                    local orig_img
                    orig_img=$(echo "$docker_img" | sed 's|^[^/]*/||; s|:.*||')
                    orig_img="knowhunters/$orig_img"
                    apply_image_mirror "$compose_file" "$orig_img"
                else
                    echo -e "${GREEN}✓ Direct network access OK${NC}"
                fi
                echo ""
                echo -e "${BLUE}Pulling latest image... / 正在拉取最新镜像...${NC}"
                if ! $cr pull 2>&1; then
                    if [ "$NEED_MIRROR" = true ]; then
                        echo -e "${YELLOW}Mirror pull failed, reverting... / 镜像加速失败，回退直连...${NC}"
                        local orig_img2
                        orig_img2=$(echo "$docker_img" | sed 's|^[^/]*/||; s|:.*||')
                        orig_img2="knowhunters/$orig_img2"
                        revert_image_mirror "$compose_file" "$orig_img2"
                        $cr pull 2>&1
                    fi
                fi
                echo ""
                echo -e "${BLUE}Recreating container... / 正在重建容器...${NC}"
                $cr up -d
                echo ""
                # Wait briefly for health
                local uw=0
                while [ $uw -lt 30 ]; do
                    if [ -n "$compose_ports" ]; then
                        local first_port
                        first_port=$(echo "$compose_ports" | awk -F: '{print $1}' | awk '{print $1}')
                        if curl -sf "http://localhost:${first_port}/api/v1/health" >/dev/null 2>&1; then break; fi
                    fi
                    sleep 2; uw=$((uw + 2))
                done
                local new_ver
                new_ver=$(docker inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$container" 2>/dev/null || echo "unknown")
                [ "$new_ver" = "<no value>" ] && new_ver="unknown"
                echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
                echo -e "${GREEN}  ✅ Update complete! / 更新完成！${NC}"
                echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
                echo -e "  Previous / 旧版本: $docker_ver"
                echo -e "  Current  / 新版本: $new_ver"
                ;;
            2)
                if [ "$is_running" = true ]; then
                    echo ""
                    echo -e "${BLUE}Stopping container... / 正在停止容器...${NC}"
                    $cr stop
                    echo -e "${GREEN}✓ Stopped / 已停止${NC}"
                else
                    echo ""
                    echo -e "${BLUE}Starting container... / 正在启动容器...${NC}"
                    $cr up -d
                    sleep 2
                    echo -e "${GREEN}✓ Started / 已启动${NC}"
                    if [ -n "$compose_ports" ]; then
                        for _pp in $compose_ports; do
                            local _hp="${_pp%%:*}"
                            print_access_urls "$_hp" "$container"
                        done
                    fi
                fi
                ;;
            3)
                echo ""
                echo -e "${BLUE}Restarting container... / 正在重启容器...${NC}"
                $cr restart
                echo -e "${GREEN}✓ Restarted / 已重启${NC}"
                ;;
            4)
                echo ""
                echo -e "${CYAN}Recent logs / 最近日志：${NC}"
                echo "────────────────────────────────────────"
                $cr logs --tail 80
                echo "────────────────────────────────────────"
                ;;
            5)
                echo ""
                $cr ps
                echo ""
                if [ "$is_running" = true ] && [ -n "$compose_ports" ]; then
                    for _pp in $compose_ports; do
                        local _hp="${_pp%%:*}"
                        print_access_urls "$_hp" "$container"
                        echo ""
                    done
                fi
                ;;
            6)
                # Uninstall with options
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}  Uninstall / 卸载: ${container}${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "${CYAN}This will: / 将执行：${NC}"
                echo "  - Stop and remove the container / 停止并删除容器"
                echo ""

                local remove_volumes=false
                echo -n "Also remove data volumes? (config, database, logs) / 同时删除数据卷？ [y/N] "
                read -n 1 -r </dev/tty; echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    remove_volumes=true
                    echo -e "  ${RED}- Data volumes will be removed / 数据卷将被删除${NC}"
                fi

                local remove_image=false
                echo -n "Also remove Docker image? / 同时删除 Docker 镜像？ [y/N] "
                read -n 1 -r </dev/tty; echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    remove_image=true
                    echo -e "  ${RED}- Docker image will be removed / Docker 镜像将被删除${NC}"
                fi

                local remove_compose=false
                echo -n "Also remove ${compose_file}? / 同时删除 ${compose_file}？ [y/N] "
                read -n 1 -r </dev/tty; echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    remove_compose=true
                    echo -e "  ${RED}- ${compose_file} will be removed / ${compose_file} 将被删除${NC}"
                fi

                echo ""
                echo -n -e "${RED}Confirm uninstall? / 确认卸载？ [y/N] ${NC}"
                read -n 1 -r </dev/tty; echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Uninstall cancelled / 卸载已取消${NC}"
                    return
                fi

                echo ""
                if [ "$remove_volumes" = true ]; then
                    $cr down -v
                    echo -e "${GREEN}✓ Container and volumes removed / 容器和数据卷已删除${NC}"
                else
                    $cr down
                    echo -e "${GREEN}✓ Container removed (volumes preserved) / 容器已删除（数据卷已保留）${NC}"
                fi

                if [ "$remove_image" = true ]; then
                    echo -e "${BLUE}Removing Docker image... / 正在删除 Docker 镜像...${NC}"
                    docker rmi "$docker_img" 2>/dev/null || true
                    echo -e "${GREEN}✓ Image removed / 镜像已删除${NC}"
                fi

                if [ "$remove_compose" = true ]; then
                    rm -f "$compose_file"
                    echo -e "${GREEN}✓ ${compose_file} removed / ${compose_file} 已删除${NC}"
                fi

                echo ""
                echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
                echo -e "${GREEN}  ✅ Uninstall complete! / 卸载完成！${NC}"
                echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
                ;;
            7)
                exec bash "$SELF_SCRIPT" "$@"
                ;;
            *)
                echo -e "${RED}Invalid choice / 选择无效${NC}"
                ;;
        esac
    else
        # No compose file — use raw docker commands
        case "$MGMT_CHOICE" in
            1)
                if [ -n "$docker_img" ] && [ "$docker_img" != "unknown" ]; then
                    echo ""
                    echo -e "${BLUE}Pulling latest image: ${docker_img}${NC}"
                    echo -e "${BLUE}正在拉取最新镜像...${NC}"
                    docker pull "$docker_img"
                    echo ""
                    echo -e "${YELLOW}⚠ No compose file found. Container must be recreated manually.${NC}"
                    echo -e "${YELLOW}  未找到 compose 文件。需要手动重建容器。${NC}"
                    echo ""
                    echo -e "${CYAN}Recommended: re-run the installer to deploy a new instance:${NC}"
                    echo -e "${CYAN}建议：重新运行安装脚本以部署新实例：${NC}"
                    echo ""
                    echo -e "  ${GREEN}curl -fsSL https://raw.githubusercontent.com/KnowHunters/DeckXHub/main/install.sh | bash${NC}"
                else
                    echo -e "${RED}Cannot determine image name / 无法确定镜像名称${NC}"
                fi
                ;;
            2)
                if [ "$is_running" = true ]; then
                    echo -e "${BLUE}Stopping container... / 正在停止容器...${NC}"
                    docker stop "$container"
                    echo -e "${GREEN}✓ Stopped / 已停止${NC}"
                else
                    echo -e "${BLUE}Starting container... / 正在启动容器...${NC}"
                    docker start "$container"
                    sleep 2
                    echo -e "${GREEN}✓ Started / 已启动${NC}"
                    local _ports
                    _ports=$(docker port "$container" 2>/dev/null | sed 's|.*:||; s|/.*||' | sort -u)
                    for _p in $_ports; do
                        print_access_urls "$_p" "$container"
                    done
                fi
                ;;
            3)
                echo -e "${BLUE}Restarting container... / 正在重启容器...${NC}"
                docker restart "$container"
                echo -e "${GREEN}✓ Restarted / 已重启${NC}"
                ;;
            4)
                echo ""
                echo -e "${CYAN}Recent logs / 最近日志：${NC}"
                echo "────────────────────────────────────────"
                docker logs --tail 80 "$container"
                echo "────────────────────────────────────────"
                ;;
            5)
                echo ""
                docker ps -a --filter "name=^${container}$"
                echo ""
                if [ "$is_running" = true ]; then
                    local _ports
                    _ports=$(docker port "$container" 2>/dev/null | sed 's|.*:||; s|/.*||' | sort -u)
                    for _p in $_ports; do
                        print_access_urls "$_p" "$container"
                        echo ""
                    done
                fi
                ;;
            6)
                # Full uninstall flow (no compose file)
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}  Uninstall / 卸载: ${container}${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "${CYAN}This will: / 将执行：${NC}"
                echo "  - Stop and remove the container / 停止并删除容器"
                echo ""

                # Find volumes attached to this container
                local container_vols
                container_vols=$(docker inspect --format '{{ range .Mounts }}{{ .Name }} {{ end }}' "$container" 2>/dev/null || true)

                local remove_volumes=false
                if [ -n "$container_vols" ]; then
                    echo -e "${CYAN}Data volumes / 数据卷：${NC}"
                    for _vn in $container_vols; do
                        echo -e "  - ${_vn}"
                    done
                    echo ""
                    echo -n "Also remove data volumes? / 同时删除数据卷？ [y/N] "
                    read -n 1 -r </dev/tty; echo
                    if [[ $REPLY =~ ^[Yy]$ ]]; then
                        remove_volumes=true
                        echo -e "  ${RED}- Data volumes will be removed / 数据卷将被删除${NC}"
                    fi
                fi

                local remove_image=false
                echo -n "Also remove Docker image ($docker_img)? / 同时删除 Docker 镜像？ [y/N] "
                read -n 1 -r </dev/tty; echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    remove_image=true
                    echo -e "  ${RED}- Docker image will be removed / Docker 镜像将被删除${NC}"
                fi

                echo ""
                echo -n -e "${RED}Confirm uninstall? / 确认卸载？ [y/N] ${NC}"
                read -n 1 -r </dev/tty; echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}Uninstall cancelled / 卸载已取消${NC}"
                    exit 0
                fi

                echo ""
                echo -e "${BLUE}Stopping and removing container... / 正在停止并删除容器...${NC}"
                docker stop "$container" 2>/dev/null || true
                docker rm "$container" 2>/dev/null || true
                echo -e "${GREEN}✓ Container removed / 容器已删除${NC}"

                if [ "$remove_volumes" = true ] && [ -n "$container_vols" ]; then
                    echo -e "${BLUE}Removing data volumes... / 正在删除数据卷...${NC}"
                    for _vn in $container_vols; do
                        docker volume rm "$_vn" 2>/dev/null || true
                    done
                    echo -e "${GREEN}✓ Volumes removed / 数据卷已删除${NC}"
                fi

                if [ "$remove_image" = true ]; then
                    echo -e "${BLUE}Removing Docker image... / 正在删除 Docker 镜像...${NC}"
                    docker rmi "$docker_img" 2>/dev/null || true
                    echo -e "${GREEN}✓ Image removed / 镜像已删除${NC}"
                fi

                echo ""
                echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
                echo -e "${GREEN}  ✅ Uninstall complete! / 卸载完成！${NC}"
                echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
                ;;
            7) exec bash "$SELF_SCRIPT" "$@" ;;
            *) echo -e "${RED}Invalid choice / 选择无效${NC}" ;;
        esac
    fi
    exit 0
}

# ==============================================================================
# Main Entry Point
# ==============================================================================
echo -e "${BLUE}"
cat << 'LOGO'
  ___          _   __  _  _       _
 |   \ ___ __ | |_\ \/ || |_  _ | |__
 | |) / -_) _|| / / >  <| ' \| || '_ \
 |___/\___|__||_\_\/_/\_\_||_|\__|_.__/
LOGO
echo -e "${NC}"
echo -e "${CYAN}:: DeckXHub — Unified AI Agent Docker Manager ::${NC}"
echo ""

# Detect existing deployments
detect_deployments

if [ ${#DETECTED_DEPLOYMENTS[@]} -gt 0 ] || [ ${#DETECTED_COMPOSE_FILES[@]} -gt 0 ]; then
    echo -e "${CYAN}Detected deployments / 检测到的部署：${NC}"
    for d in "${DETECTED_DEPLOYMENTS[@]}"; do
        d_status=$(docker inspect --format='{{.State.Status}}' "$d" 2>/dev/null || echo "unknown")
        d_img=$(docker inspect --format='{{.Config.Image}}' "$d" 2>/dev/null || echo "unknown")
        if [ "$d_status" = "running" ]; then
            echo -e "  🐳 ${BOLD}${d}${NC}  [${GREEN}${d_status}${NC}]  ${d_img}"
        else
            echo -e "  🐳 ${BOLD}${d}${NC}  [${YELLOW}${d_status}${NC}]  ${d_img}"
        fi
    done
    for cf in "${DETECTED_COMPOSE_FILES[@]}"; do
        cf_shown=false
        for d in "${DETECTED_DEPLOYMENTS[@]}"; do
            if echo "$cf" | grep -q "$d" 2>/dev/null; then cf_shown=true; break; fi
        done
        if [ "$cf_shown" = false ]; then
            echo -e "  📄 ${cf} (${YELLOW}no container${NC})"
        fi
    done
    echo ""
fi

# Main menu
echo -e "${YELLOW}What would you like to do? / 您想做什么？${NC}"
echo ""
echo -e "  ${BOLD}── Install / 安装 ──${NC}"
echo "  1) ClawDeckX + OpenClaw          (image: knowhunters/clawdeckx)"
echo "  2) HermesDeckX + HermesAgent     (image: knowhunters/hermesdeckx)"
echo "  3) Both — unified DeckXHub       (image: knowhunters/deckxhub)"
echo ""

HAS_EXISTING=false
if [ ${#DETECTED_DEPLOYMENTS[@]} -gt 0 ]; then
    HAS_EXISTING=true
    echo -e "  ${BOLD}── Manage / 管理 ──${NC}"
    mgmt_idx=4
    MGMT_MAP=()
    for d in "${DETECTED_DEPLOYMENTS[@]}"; do
        d_status=$(docker inspect --format='{{.State.Status}}' "$d" 2>/dev/null || echo "unknown")
        if [ "$d_status" = "running" ]; then
            echo -e "  ${mgmt_idx}) Manage: ${d}  [${GREEN}${d_status}${NC}]"
        else
            echo -e "  ${mgmt_idx}) Manage: ${d}  [${YELLOW}${d_status}${NC}]"
        fi
        MGMT_MAP+=("$d")
        mgmt_idx=$((mgmt_idx + 1))
    done
    echo ""
    echo "  ${mgmt_idx}) Exit / 退出"
    MENU_MAX=$mgmt_idx
else
    echo "  4) Exit / 退出"
    MENU_MAX=4
fi
echo ""
echo -n "Enter your choice [1-$MENU_MAX] / 输入选择 [1-$MENU_MAX]: "
read -r MAIN_CHOICE </dev/tty

case "$MAIN_CHOICE" in
    1)
        docker_install "clawdeckx"
        ;;
    2)
        docker_install "hermesdeckx"
        ;;
    3)
        docker_install "both"
        ;;
    *)
        if [ "$HAS_EXISTING" = true ]; then
            idx=$((MAIN_CHOICE - 4))
            if [ "$idx" -ge 0 ] 2>/dev/null && [ "$idx" -lt "${#MGMT_MAP[@]}" ] 2>/dev/null; then
                manage_deployment "${MGMT_MAP[$idx]}"
            elif [ "$MAIN_CHOICE" = "$MENU_MAX" ]; then
                echo -e "${YELLOW}Bye / 再见${NC}"
            else
                echo -e "${RED}Invalid choice / 选择无效${NC}"
            fi
        else
            if [ "$MAIN_CHOICE" = "4" ]; then
                echo -e "${YELLOW}Bye / 再见${NC}"
            else
                echo -e "${RED}Invalid choice / 选择无效${NC}"
            fi
        fi
        ;;
esac
