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
# Scans for running containers and compose files from all three profiles
detect_deployments() {
    DETECTED_DEPLOYMENTS=()
    DETECTED_COMPOSE_FILES=()

    # Check running Docker containers
    if check_docker 2>/dev/null; then
        for cname in clawdeckx hermesdeckx deckxhub; do
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cname"; then
                DETECTED_DEPLOYMENTS+=("$cname")
            fi
        done
    fi

    # Check local compose files
    for cf in docker-compose.yml docker-compose-clawdeckx.yml docker-compose-hermesdeckx.yml; do
        if [ -f "$cf" ]; then
            DETECTED_COMPOSE_FILES+=("$cf")
        fi
    done
}

# ==============================================================================
# Docker Install — core function for all three modes
# ==============================================================================
docker_install() {
    local mode="$1"
    set_deploy_profile "$mode"

    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}  Deploy: ${DP_NAME}${NC}"
    echo -e "${YELLOW}  Image:  ${DP_IMAGE}${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Network detection
    echo -e "${CYAN}Checking network connectivity...${NC}"
    if detect_network; then
        NEED_MIRROR=true; DOCKER_MIRROR="${DOCKER_MIRRORS[0]}"
        echo -e "${YELLOW}⚠ Using mirror proxies / 已启用镜像加速代理${NC}"
    else
        echo -e "${GREEN}✓ Direct network access OK${NC}"
    fi
    echo ""

    # Ensure Docker is installed and running
    if ! check_docker verbose; then
        local docker_status=$?
        if [ $docker_status -eq 1 ]; then
            echo -n "Docker not installed. Install now? / 未安装 Docker，立即安装？ [Y/n] "
            read -n 1 -r </dev/tty; echo
            if [[ $REPLY =~ ^[Nn]$ ]]; then echo -e "${RED}Aborted.${NC}"; exit 1; fi
            if ! install_docker_engine; then exit 1; fi
        else
            echo -e "${RED}Docker daemon is not running. Please start it first.${NC}"; exit 1
        fi
    fi
    if ! check_docker_compose; then
        echo -e "${RED}✗ docker compose not found. Please install Docker Compose.${NC}"; exit 1
    fi
    echo -e "${GREEN}✓ Docker is ready${NC}"

    # Configure mirror if needed
    if [ "$NEED_MIRROR" = true ]; then configure_docker_mirror; echo ""; fi

    # Check for existing container with same name
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DP_CONTAINER"; then
        echo -e "${YELLOW}⚠ Container '${DP_CONTAINER}' already exists.${NC}"
        echo -n "Stop and recreate? / 停止并重建？ [Y/n] "
        read -n 1 -r </dev/tty; echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then echo -e "${YELLOW}Aborted.${NC}"; exit 0; fi
        if [ -f "$DP_COMPOSE_FILE" ] && check_docker_compose; then
            $COMPOSE_CMD -f "$DP_COMPOSE_FILE" -p "$DP_PROJECT" down 2>/dev/null || true
        else
            docker stop "$DP_CONTAINER" 2>/dev/null || true
            docker rm "$DP_CONTAINER" 2>/dev/null || true
        fi
        echo ""
    fi

    # Download docker-compose.yml from the appropriate project
    echo -e "${CYAN}Downloading docker-compose.yml for ${DP_NAME}...${NC}"
    download_with_fallback "$DP_COMPOSE_URL" "$DP_COMPOSE_URL_CN" "$DP_COMPOSE_FILE"
    echo -e "${GREEN}✓ Downloaded: ${DP_COMPOSE_FILE}${NC}"

    # Port auto-detection and customization
    echo ""
    echo -e "${CYAN}Detecting available ports...${NC}"
    local host_ports=()
    local idx=0
    for mapping in "${DP_PORT_MAPPINGS[@]}"; do
        local default_host="${mapping%%:*}"
        local container_port="${mapping##*:}"
        local label="${DP_PORT_LABELS[$idx]}"

        find_available_port "$default_host"
        local chosen_port=$FOUND_PORT

        if [ "$chosen_port" -ne "$default_host" ]; then
            echo -e "${YELLOW}  ${label}: default ${default_host} occupied → using ${chosen_port}${NC}"
        else
            echo -e "${GREEN}  ✓ ${label}: port ${chosen_port}${NC}"
        fi

        # Update compose file with chosen port
        if [ "$chosen_port" -ne "$default_host" ]; then
            sed_inplace "s|\"${default_host}:${container_port}\"|\"${chosen_port}:${container_port}\"|" "$DP_COMPOSE_FILE"
        fi

        host_ports+=("$chosen_port")
        idx=$((idx + 1))
    done

    # Apply image mirror if needed
    apply_image_mirror "$DP_COMPOSE_FILE" "$DP_ORIGINAL_IMAGE"

    local compose_run="$COMPOSE_CMD -f $DP_COMPOSE_FILE -p $DP_PROJECT"

    # Pull image
    echo ""
    echo -e "${BLUE}Pulling Docker image: ${DP_IMAGE}${NC}"
    echo -e "${BLUE}正在拉取 Docker 镜像...${NC}"
    if ! $compose_run pull 2>&1; then
        if [ "$NEED_MIRROR" = true ]; then
            echo -e "${YELLOW}Mirror pull failed, trying direct... / 镜像拉取失败，尝试直连...${NC}"
            revert_image_mirror "$DP_COMPOSE_FILE" "$DP_ORIGINAL_IMAGE"
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

    echo -e "${YELLOW}Management commands / 管理命令：${NC}"
    echo -e "  ${GREEN}${compose_run} ps${NC}              — Status / 状态"
    echo -e "  ${GREEN}${compose_run} logs --tail 50${NC}  — Logs / 日志"
    echo -e "  ${GREEN}${compose_run} restart${NC}         — Restart / 重启"
    echo -e "  ${GREEN}${compose_run} stop${NC}            — Stop / 停止"
    echo -e "  ${GREEN}${compose_run} down${NC}            — Remove / 删除容器"
    echo -e "  ${GREEN}${compose_run} pull && ${compose_run} up -d${NC} — Update / 更新"
    echo ""
}

# ==============================================================================
# Management menu for existing deployments
# ==============================================================================
manage_deployment() {
    local container="$1"

    # Find matching compose file
    local compose_file="" project=""
    case "$container" in
        clawdeckx)   compose_file="docker-compose-clawdeckx.yml"; project="clawdeckx" ;;
        hermesdeckx) compose_file="docker-compose-hermesdeckx.yml"; project="hermesdeckx" ;;
        deckxhub)    compose_file="docker-compose.yml"; project="deckxhub" ;;
    esac

    if [ ! -f "$compose_file" ]; then
        echo -e "${YELLOW}No compose file found for ${container}. Using docker commands directly.${NC}"
        compose_file=""
    fi

    echo ""
    echo -e "${CYAN}Managing: ${BOLD}${container}${NC}"
    echo ""
    echo "  1) Status / 状态"
    echo "  2) Logs / 日志"
    echo "  3) Restart / 重启"
    echo "  4) Stop / 停止"
    echo "  5) Update (pull + recreate) / 更新"
    echo "  6) Remove (stop + delete) / 卸载"
    echo "  7) Back / 返回"
    echo ""
    echo -n "Choice / 选择 [1-7]: "
    read -n 1 -r </dev/tty; echo

    if [ -n "$compose_file" ] && check_docker_compose; then
        local cr="$COMPOSE_CMD -f $compose_file -p $project"
        case "$REPLY" in
            1) $cr ps ;;
            2) $cr logs --tail 80 ;;
            3) $cr restart; echo -e "${GREEN}✓ Restarted${NC}" ;;
            4) $cr stop; echo -e "${GREEN}✓ Stopped${NC}" ;;
            5)
                echo -e "${CYAN}Pulling latest image... / 拉取最新镜像...${NC}"
                $cr pull
                $cr up -d
                echo -e "${GREEN}✓ Updated / 已更新${NC}"
                ;;
            6)
                echo -n "Are you sure? This will delete the container. Data volumes are kept. / 确定卸载？数据卷会保留。 [y/N] "
                read -n 1 -r </dev/tty; echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    $cr down
                    rm -f "$compose_file"
                    echo -e "${GREEN}✓ Removed / 已卸载${NC}"
                fi
                ;;
            7) return ;;
            *) echo -e "${RED}Invalid choice${NC}" ;;
        esac
    else
        case "$REPLY" in
            1) docker ps -a --filter "name=$container" ;;
            2) docker logs --tail 80 "$container" ;;
            3) docker restart "$container"; echo -e "${GREEN}✓ Restarted${NC}" ;;
            4) docker stop "$container"; echo -e "${GREEN}✓ Stopped${NC}" ;;
            5)
                local img; img=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null)
                if [ -n "$img" ]; then
                    docker pull "$img"
                    docker stop "$container" 2>/dev/null || true
                    docker rm "$container" 2>/dev/null || true
                    echo -e "${YELLOW}Container removed. Re-run install to recreate.${NC}"
                fi
                ;;
            6)
                echo -n "Are you sure? [y/N] "
                read -n 1 -r </dev/tty; echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    docker stop "$container" 2>/dev/null || true
                    docker rm "$container" 2>/dev/null || true
                    echo -e "${GREEN}✓ Removed${NC}"
                fi
                ;;
            7) return ;;
            *) echo -e "${RED}Invalid choice${NC}" ;;
        esac
    fi
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
        status=$(docker inspect --format='{{.State.Status}}' "$d" 2>/dev/null || echo "unknown")
        img=$(docker inspect --format='{{.Config.Image}}' "$d" 2>/dev/null || echo "unknown")
        echo -e "  🐳 ${BOLD}${d}${NC}  [${GREEN}${status}${NC}]  ${img}"
    done
    for cf in "${DETECTED_COMPOSE_FILES[@]}"; do
        already_shown=false
        for d in "${DETECTED_DEPLOYMENTS[@]}"; do
            if echo "$cf" | grep -q "$d" 2>/dev/null; then already_shown=true; break; fi
        done
        if [ "$already_shown" = false ]; then
            echo -e "  📄 ${cf} (container not running)"
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
        echo "  ${mgmt_idx}) Manage: ${d}"
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
read -n 1 -r MAIN_CHOICE </dev/tty
echo

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
