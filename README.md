# DeckXHub

Unified Docker manager for **ClawDeckX** and **HermesDeckX** — two AI agent management dashboards.

## Three Deployment Modes

| Mode | Docker Image | Components |
|------|-------------|------------|
| **ClawDeckX only** | `knowhunters/clawdeckx` (existing) | ClawDeckX + OpenClaw Gateway |
| **HermesDeckX only** | `knowhunters/hermesdeckx` (existing) | HermesDeckX + HermesAgent Gateway |
| **Both (unified)** | `knowhunters/deckxhub` (this project) | All four components |

> Single installs use each project's **existing Docker image** — no unified image needed.
> The unified `deckxhub` image is only used when deploying both together.

## Quick Start

### One-Line Install (Linux / macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/KnowHunters/DeckXHub/main/install.sh | bash
```

The interactive menu will show:

```
── Install / 安装 ──
  1) ClawDeckX + OpenClaw          (image: knowhunters/clawdeckx)
  2) HermesDeckX + HermesAgent     (image: knowhunters/hermesdeckx)
  3) Both — unified DeckXHub       (image: knowhunters/deckxhub)

── Manage / 管理 ──          (shown if deployments detected)
  4) Manage: clawdeckx
  ...
```

The installer handles Docker installation, China mirror acceleration, port detection, and container lifecycle.

### Docker Run (Manual)

```bash
# ClawDeckX + OpenClaw (existing image)
docker run -d --name clawdeckx \
  -p 18700:18788 \
  -v clawdeckx-data:/data/clawdeckx \
  -v openclaw-data:/data/openclaw \
  -v clawdeckx-runtime:/data/runtime \
  knowhunters/clawdeckx:latest

# HermesDeckX + HermesAgent (existing image)
docker run -d --name hermesdeckx \
  -p 19700:19788 \
  -v hermesdeckx-data:/data/hermesdeckx \
  -v hermesagent-data:/data/hermesagent \
  -v hermesdeckx-runtime:/data/runtime \
  knowhunters/hermesdeckx:latest

# Both — unified image
docker run -d --name deckxhub \
  -p 18700:18788 -p 19700:19788 \
  -v deckxhub-data:/data \
  knowhunters/deckxhub:latest
```

### Docker Compose (Manual)

```bash
git clone https://github.com/KnowHunters/DeckXHub.git
cd DeckXHub
docker compose up -d          # Unified image, both components
```

## Architecture

```
┌─ knowhunters/clawdeckx ─────────────────────────┐
│  ClawDeckX :18788  ◄──►  OpenClaw Gateway :18789 │
└──────────────────────────────────────────────────┘

┌─ knowhunters/hermesdeckx ────────────────────────┐
│  HermesDeckX :19788  ◄──►  HermesAgent API :8642 │
└──────────────────────────────────────────────────┘

┌─ knowhunters/deckxhub (unified) ─────────────────┐
│  ClawDeckX :18788  ◄──►  OpenClaw Gateway :18789  │
│  HermesDeckX :19788 ◄──► HermesAgent API :8642    │
│  docker-entrypoint.sh (INSTALL_MODE selector)     │
└───────────────────────────────────────────────────┘
```

## INSTALL_MODE (unified image only)

The `INSTALL_MODE` environment variable controls which components start in the unified `deckxhub` image:

| Value | Components | Ports |
|-------|-----------|-------|
| `both` (default) | ClawDeckX + OpenClaw + HermesDeckX + HermesAgent | 18788, 18789, 19788, 8642 |
| `clawdeckx` | ClawDeckX + OpenClaw | 18788, 18789 |
| `hermesdeckx` | HermesDeckX + HermesAgent | 19788, 8642 |

## Port Mapping

| Service | Container Port | Default Host Port |
|---------|---------------|-------------------|
| ClawDeckX Web UI | 18788 | 18700 |
| OpenClaw Gateway | 18789 | (internal) |
| HermesDeckX Web UI | 19788 | 19700 |
| HermesAgent API | 8642 | (internal) |

## Management

The install script includes a built-in management menu for existing deployments:
- **Status** — view container state
- **Logs** — tail container logs
- **Restart / Stop** — lifecycle control
- **Update** — pull latest image and recreate
- **Remove** — stop and delete container (data volumes preserved)

```bash
# Or manage directly via docker compose
docker compose -f docker-compose-clawdeckx.yml -p clawdeckx ps
docker compose -f docker-compose-clawdeckx.yml -p clawdeckx logs --tail 50
docker compose -f docker-compose-clawdeckx.yml -p clawdeckx restart
```

## Environment Variables

See [`.env.example`](.env.example) for all available variables.

## Building the Unified Image from Source

```bash
docker build -t deckxhub:local .

# With specific versions
docker build \
  --build-arg CLAWDECKX_REF=v0.1.0 \
  --build-arg HERMESDECKX_REF=v0.1.0 \
  --build-arg OPENCLAW_VERSION=latest \
  --build-arg HERMES_AGENT_BRANCH=main \
  -t deckxhub:local .
```

## Related Projects

- [ClawDeckX](https://github.com/ClawDeckX/ClawDeckX) — OpenClaw management dashboard
- [HermesDeckX](https://github.com/HermesDeckX/HermesDeckX) — HermesAgent management dashboard
- [OpenClaw](https://github.com/openclaw/openclaw) — AI agent gateway
- [HermesAgent](https://github.com/NousResearch/hermes-agent) — AI agent framework

## License

MIT
