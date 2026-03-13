#!/bin/bash
cd "$(dirname "$0")/.."
echo "RealSense stack indítása..."
docker compose up -d
echo ""
echo "Státusz:"
docker compose ps
echo ""
echo "Logs (Ctrl+C kilépéshez):"
echo "  docker compose logs -f ros2-realsense"
