#!/bin/bash
echo "=== hidraw devices in container ==="
docker exec ros2_realsense ls -la /dev/hidraw* 2>/dev/null || echo "No hidraw devices"

echo ""
echo "=== rs-enumerate-devices (SDK container) ==="
docker exec realsense_sdk rs-enumerate-devices -s 2>&1

echo ""
echo "=== librealsense2 backend check (ROS container) ==="
docker exec ros2_realsense dpkg -l 'ros-jazzy-librealsense2' 'librealsense2' 2>&1 | grep -E "^ii|not installed"

echo ""
echo "=== librealsense2 shared lib check ==="
docker exec ros2_realsense ldd /opt/ros/jazzy/lib/librealsense2_camera_node.so 2>/dev/null | grep realsense || \
docker exec ros2_realsense find /opt/ros/jazzy -name "*.so" | xargs grep -l "librealsense" 2>/dev/null | head -5
