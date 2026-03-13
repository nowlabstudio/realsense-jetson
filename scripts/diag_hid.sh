#!/bin/bash
echo "=== /sys/class/hidraw inside container ==="
docker exec ros2_realsense ls /sys/class/hidraw/ 2>/dev/null || echo "EMPTY or missing"

echo ""
echo "=== hidraw6 sysfs uevent inside container ==="
docker exec ros2_realsense cat /sys/class/hidraw/hidraw6/device/uevent 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== udev data for hidraw6 on HOST ==="
cat /run/udev/data/c510:6 2>/dev/null || echo "NOT FOUND"

echo ""
echo "=== Can container open hidraw6? ==="
docker exec ros2_realsense bash -c "dd if=/dev/hidraw6 of=/dev/null bs=1 count=1 2>&1 || echo FAIL"

echo ""
echo "=== rs-enumerate-devices in ROS container ==="
docker exec ros2_realsense rs-enumerate-devices -s 2>&1 || echo "rs-enumerate-devices not available in ROS container"
