#!/bin/bash
cd "$(dirname "$0")/.."
echo "=== Konténer státusz ==="
docker compose ps
echo ""
echo "=== GPU memória ==="
docker exec realsense_sdk nvidia-smi 2>/dev/null || echo "SDK konténer nem fut"
echo ""
echo "=== ROS2 topicok ==="
docker exec ros2_realsense bash -c \
    "source /opt/ros/jazzy/setup.bash && ros2 topic list 2>/dev/null" \
    2>/dev/null || echo "ROS2 konténer nem fut"
