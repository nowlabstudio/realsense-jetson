#!/bin/bash
# =============================================================================
# RealSense Viewer indítás — fejlesztési / tesztelési eszköz
# Használat: bash scripts/viewer.sh
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Image build ha még nem létezik
if ! docker image inspect realsense-viewer:2.56.5 &>/dev/null; then
    echo "[viewer] Image nem található, build indul (~30-45 perc)..."
    docker compose -f docker-compose.dev.yml build realsense-viewer
fi

# DISPLAY ellenőrzés
if [ -z "$DISPLAY" ]; then
    echo "[viewer] HIBA: DISPLAY változó nincs beállítva."
    echo "         HDMI képernyőn futtasd, vagy állítsd be: export DISPLAY=:0"
    exit 1
fi

# ros2_realsense leállítása — libusb nem osztható meg
# update restart policy → no, különben unless-stopped azonnal újraindítja
ROS2_WAS_RUNNING=false
if docker ps --format '{{.Names}}' | grep -q '^ros2_realsense$'; then
    echo "[viewer] ros2_realsense leállítása (kamera felszabadítása)..."
    docker update --restart=no ros2_realsense &>/dev/null
    docker stop ros2_realsense &>/dev/null
    sleep 1
    ROS2_WAS_RUNNING=true
fi

# X11 hozzáférés a konténernek
xhost +local:docker &>/dev/null || true

echo "[viewer] realsense-viewer indítás... (Ctrl+C = kilépés)"
docker compose -f docker-compose.dev.yml run --rm realsense-viewer

# X11 hozzáférés visszavonása
xhost -local:docker &>/dev/null || true

# ros2_realsense visszaindítása ha futott
if [ "$ROS2_WAS_RUNNING" = true ]; then
    echo "[viewer] ros2_realsense visszaindítása..."
    docker update --restart=unless-stopped ros2_realsense &>/dev/null
    docker start ros2_realsense &>/dev/null
fi
