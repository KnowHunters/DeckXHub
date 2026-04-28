#!/bin/sh
# DeckXHub mode-aware healthcheck.
# - clawdeckx   : ClawDeckX 必须健康
# - hermesdeckx : HermesDeckX 必须健康
# - both        : 两个都必须健康（AND 而非 OR，避免单边崩溃被掩盖）
set -e

mode="${INSTALL_MODE:-both}"
ocd_port="${OCD_PORT:-18788}"
ohd_port="${OHD_PORT:-19788}"

check_ocd() { curl -sf "http://localhost:${ocd_port}/api/v1/health" >/dev/null; }
check_ohd() { curl -sf "http://localhost:${ohd_port}/api/v1/health" >/dev/null; }

case "$mode" in
    clawdeckx)   check_ocd ;;
    hermesdeckx) check_ohd ;;
    both)        check_ocd && check_ohd ;;
    *)           exit 1 ;;
esac
