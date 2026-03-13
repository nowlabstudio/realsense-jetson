#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

if ! docker image inspect realsense-viewer:2.56.5 &>/dev/null; then
    echo "[viewer-debug] Image nem található, build indul (~30-45 perc)..."
    docker compose -f docker-compose.dev.yml build realsense-viewer
fi

if [ -z "$DISPLAY" ]; then
    echo "[viewer-debug] HIBA: DISPLAY nincs beállítva. Futtasd: export DISPLAY=:0"
    exit 1
fi

docker update --restart=no ros2_realsense &>/dev/null || true
docker stop ros2_realsense &>/dev/null || true
sleep 1

xhost +local:docker
docker run --rm --privileged --network host \
  --device /dev/bus/usb \
  -v /run/udev:/run/udev:ro \
  -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
  -e DISPLAY=$DISPLAY \
  realsense-viewer:2.56.5 \
  realsense-viewer 2>&1

xhost -local:docker &>/dev/null || true
docker update --restart=unless-stopped ros2_realsense &>/dev/null || true
docker start ros2_realsense &>/dev/null || true
