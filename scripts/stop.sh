#!/bin/bash
cd "$(dirname "$0")/.."
echo "RealSense stack leállítása..."
docker compose down
