# =============================================================================
# DeckXHub — Unified Docker image for ClawDeckX + HermesDeckX
# =============================================================================
# Builds everything from source in multi-stage, producing a single runtime
# image that can run ClawDeckX, HermesDeckX, or both via INSTALL_MODE env var.
#
# Stages:
#   1-2: ClawDeckX frontend + Go backend
#   3-4: HermesDeckX frontend + Go backend
#   5:   OpenClaw (npm global install)
#   6:   HermesAgent (Python/uv)
#   7:   Runtime (merge all artifacts)
# =============================================================================

# ── Stage 1: ClawDeckX Frontend ──
FROM node:24-alpine AS clawdeckx-frontend
WORKDIR /build
ARG CLAWDECKX_REPO=https://github.com/ClawDeckX/ClawDeckX.git
ARG CLAWDECKX_REF=main
RUN apk add --no-cache git && \
    git clone --depth 1 --branch "${CLAWDECKX_REF}" "${CLAWDECKX_REPO}" /build/clawdeckx
WORKDIR /build/clawdeckx/web
RUN npm ci && npm run build

# ── Stage 2: ClawDeckX Backend ──
FROM golang:1.24-alpine AS clawdeckx-backend
WORKDIR /build/clawdeckx
COPY --from=clawdeckx-frontend /build/clawdeckx /build/clawdeckx
COPY --from=clawdeckx-frontend /build/clawdeckx/internal/web/dist ./internal/web/dist
ARG CLAWDECKX_VERSION=0.0.1
ARG BUILD_NUMBER=0
RUN COMPAT=$(grep -o '"openclawCompat"[[:space:]]*:[[:space:]]*"[^"]*"' web/package.json | cut -d'"' -f4) && \
    CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X ClawDeckX/internal/version.Version=${CLAWDECKX_VERSION} -X ClawDeckX/internal/version.Build=${BUILD_NUMBER} -X 'ClawDeckX/internal/version.OpenClawCompat=${COMPAT}'" \
    -o /clawdeckx ./cmd/clawdeckx

# ── Stage 3: HermesDeckX Frontend ──
FROM node:24-alpine AS hermesdeckx-frontend
WORKDIR /build
ARG HERMESDECKX_REPO=https://github.com/HermesDeckX/HermesDeckX.git
ARG HERMESDECKX_REF=main
RUN apk add --no-cache git && \
    git clone --depth 1 --branch "${HERMESDECKX_REF}" "${HERMESDECKX_REPO}" /build/hermesdeckx
WORKDIR /build/hermesdeckx/web
RUN npm ci && npm run build

# ── Stage 4: HermesDeckX Backend ──
FROM golang:1.24-alpine AS hermesdeckx-backend
WORKDIR /build/hermesdeckx
COPY --from=hermesdeckx-frontend /build/hermesdeckx /build/hermesdeckx
COPY --from=hermesdeckx-frontend /build/hermesdeckx/internal/web/dist ./internal/web/dist
ARG HERMESDECKX_VERSION=0.0.1
ARG BUILD_NUMBER=0
RUN COMPAT=$(grep -o '"hermesagentCompat"[[:space:]]*:[[:space:]]*"[^"]*"' web/package.json | cut -d'"' -f4) && \
    CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X HermesDeckX/internal/version.Version=${HERMESDECKX_VERSION} -X HermesDeckX/internal/version.Build=${BUILD_NUMBER} -X 'HermesDeckX/internal/version.HermesAgentCompat=${COMPAT}'" \
    -o /hermesdeckx ./cmd/hermesdeckx

# ── Stage 5: Install OpenClaw (npm) ──
FROM ubuntu:22.04 AS openclaw-builder
ENV DEBIAN_FRONTEND=noninteractive
ARG OPENCLAW_VERSION=latest
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg python3 make g++ && \
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*
RUN npm install -g "openclaw@${OPENCLAW_VERSION}" && \
    OPENCLAW_SOURCE="$(npm root -g)/openclaw" && \
    test -f "${OPENCLAW_SOURCE}/openclaw.mjs" && \
    mkdir -p /opt && \
    cp -a "${OPENCLAW_SOURCE}" /opt/openclaw && \
    printf '%s\n' '#!/bin/sh' "exec /opt/openclaw/openclaw.mjs \"\$@\"" > /usr/local/bin/openclaw && \
    chmod +x /usr/local/bin/openclaw && \
    /usr/local/bin/openclaw --version > /tmp/openclaw-version && \
    find /opt/openclaw -name '*.map' -print | xargs rm -f 2>/dev/null || true

# ── Stage 6: Install HermesAgent (Python/uv) ──
FROM ubuntu:22.04 AS hermesagent-builder
ENV DEBIAN_FRONTEND=noninteractive
ARG HERMES_AGENT_BRANCH=main
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl git software-properties-common gnupg dirmngr build-essential libffi-dev; \
    if ! command -v python3.11 >/dev/null 2>&1; then \
        add-apt-repository -y ppa:deadsnakes/ppa; \
        apt-get update; \
        apt-get install -y --no-install-recommends python3.11 python3.11-dev python3.11-venv; \
    fi; \
    rm -rf /var/lib/apt/lists/*; \
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
RUN set -eux; \
    git clone --depth 1 --branch "${HERMES_AGENT_BRANCH}" \
        https://github.com/NousResearch/hermes-agent.git /opt/hermesagent; \
    cd /opt/hermesagent; \
    uv venv venv --python python3.11; \
    VIRTUAL_ENV=/opt/hermesagent/venv uv pip install -e ".[all]"; \
    /opt/hermesagent/venv/bin/hermes --version; \
    rm -rf /root/.cache /tmp/* /opt/hermesagent/.git

# ── Stage 7: Runtime ──
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN set -eux; \
    retry_apt() { \
      for attempt in 1 2 3; do \
        if "$@"; then return 0; fi; \
        echo "==> apt failed attempt ${attempt}: $*"; \
        dpkg --configure -a || true; \
        apt-get -f install -y || true; \
        sleep 5; \
      done; \
      return 1; \
    }; \
    retry_apt apt-get update; \
    retry_apt apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg software-properties-common dirmngr; \
    # Node.js 24
    mkdir -p /etc/apt/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list; \
    retry_apt apt-get update; \
    retry_apt apt-get install -y --no-install-recommends \
        nodejs make tzdata tini wget jq ripgrep procps lsof ffmpeg golang; \
    # Python 3.11
    if ! command -v python3.11 >/dev/null 2>&1; then \
      add-apt-repository -y ppa:deadsnakes/ppa; \
      retry_apt apt-get update; \
      retry_apt apt-get install -y --no-install-recommends python3.11 python3.11-venv; \
    fi; \
    rm -rf /var/lib/apt/lists/*; \
    # uv
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# OCI metadata
ARG BUILD_VERSION=0.0.0
ARG BUILD_REVISION=unknown
ARG BUILD_DATE=unknown
ARG CLAWDECKX_VERSION=unknown
ARG HERMESDECKX_VERSION=unknown
ARG OPENCLAW_VERSION=latest
ARG HERMES_AGENT_VERSION=latest
LABEL org.opencontainers.image.title="DeckXHub" \
      org.opencontainers.image.description="Unified Docker image: ClawDeckX + HermesDeckX with OpenClaw and HermesAgent" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REVISION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.url="https://github.com/KnowHunters/DeckXHub" \
      org.opencontainers.image.source="https://github.com/KnowHunters/DeckXHub" \
      org.opencontainers.image.licenses="MIT" \
      ai.deckxhub.clawdeckx.version="${CLAWDECKX_VERSION}" \
      ai.deckxhub.hermesdeckx.version="${HERMESDECKX_VERSION}" \
      ai.deckxhub.openclaw.version="${OPENCLAW_VERSION}" \
      ai.deckxhub.hermesagent.version="${HERMES_AGENT_VERSION}"

WORKDIR /app

# Copy OpenClaw runtime
COPY --from=openclaw-builder /opt/openclaw /opt/openclaw
COPY --from=openclaw-builder /usr/local/bin/openclaw /usr/local/bin/openclaw

# Copy HermesAgent runtime
COPY --from=hermesagent-builder /opt/hermesagent /opt/hermesagent

# Copy DeckX binaries
COPY --from=clawdeckx-backend /clawdeckx ./clawdeckx
COPY --from=hermesdeckx-backend /hermesdeckx ./hermesdeckx

# Copy entrypoint + healthcheck
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
COPY healthcheck.sh /app/healthcheck.sh

# Create data directories and symlinks
RUN mkdir -p \
        /data/clawdeckx /data/openclaw/npm /data/openclaw/state /data/openclaw/logs \
        /data/openclaw/home /data/openclaw/bootstrap \
        /data/hermesdeckx /data/hermesagent/state /data/hermesagent/logs \
        /data/hermesagent/home /data/hermesagent/bootstrap \
        /data/runtime/clawdeckx /data/runtime/openclaw \
        /data/runtime/hermesdeckx /data/runtime/hermesagent \
        /data/shared/workspace /data/shared/credentials \
        /data/shared/skills /data/shared/knowledge /data/shared/mcp && \
    chmod +x ./clawdeckx ./hermesdeckx /app/docker-entrypoint.sh /app/healthcheck.sh && \
    ln -sf /app/clawdeckx /usr/local/bin/clawdeckx && \
    ln -sf /app/hermesdeckx /usr/local/bin/hermesdeckx && \
    ln -sf /opt/hermesagent/venv/bin/hermes /usr/local/bin/hermes

VOLUME ["/data"]

# ClawDeckX:18788  OpenClaw Gateway:18789  HermesDeckX:19788  HermesAgent API:8642
EXPOSE 18788 18789 19788 8642

# Default: run all components. Override INSTALL_MODE to run only one product.
ENV INSTALL_MODE=both \
    OCD_DB_SQLITE_PATH=/data/clawdeckx/ClawDeckX.db \
    OCD_LOG_FILE=/data/clawdeckx/ClawDeckX.log \
    OCD_CONFIG=/data/clawdeckx/ClawDeckX.json \
    OPENCLAW_HOME=/data/openclaw/home \
    OPENCLAW_STATE_DIR=/data/openclaw/state \
    OPENCLAW_CONFIG_PATH=/data/openclaw/state/openclaw.json \
    NPM_CONFIG_PREFIX=/data/openclaw/npm \
    OCD_GATEWAY_LOG=/data/openclaw/logs/gateway.log \
    OCD_SETUP_INSTALL_LOG=/data/openclaw/logs/install.log \
    OCD_SETUP_DOCTOR_LOG=/data/openclaw/logs/doctor.log \
    OCD_RUNTIME_DIR=/data/runtime \
    OCD_BIND=0.0.0.0 \
    OCD_PORT=18788 \
    OHD_DB_SQLITE_PATH=/data/hermesdeckx/HermesDeckX.db \
    OHD_LOG_FILE=/data/hermesdeckx/HermesDeckX.log \
    OHD_CONFIG=/data/hermesdeckx/HermesDeckX.json \
    HERMES_HOME=/data/hermesagent/home \
    HERMES_AGENT_STATE_DIR=/data/hermesagent/state \
    OHD_GATEWAY_LOG=/data/hermesagent/logs/gateway.log \
    OHD_SETUP_INSTALL_LOG=/data/hermesagent/logs/install.log \
    OHD_SETUP_DOCTOR_LOG=/data/hermesagent/logs/doctor.log \
    OHD_RUNTIME_DIR=/data/runtime \
    OHD_BIND=0.0.0.0 \
    OHD_PORT=19788 \
    DECKXHUB_SHARED_DIR=/data/shared \
    WORKSPACE_DIR=/data/shared/workspace \
    VIRTUAL_ENV=/opt/hermesagent/venv \
    PATH=/data/openclaw/npm/bin:/opt/hermesagent/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    TZ=UTC

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD /app/healthcheck.sh

ENTRYPOINT ["/usr/bin/tini", "-s", "--"]
CMD ["/app/docker-entrypoint.sh"]
