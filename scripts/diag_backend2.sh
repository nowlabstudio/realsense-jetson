#!/bin/bash
echo "=== RSUSB backend compile flag check ==="
docker exec ros2_realsense bash -c "strings /opt/ros/jazzy/lib/aarch64-linux-gnu/librealsense2.so.2.56.4 2>/dev/null | grep -iE 'rsusb|v4l2|force_rsusb|backend' | sort -u | head -20"

echo ""
echo "=== rs-enumerate-devices in ROS container ==="
docker exec ros2_realsense rs-enumerate-devices -s 2>&1 | head -40

echo ""
echo "=== librealsense udev rules on host ==="
ls /etc/udev/rules.d/ | grep -i realsense
cat /etc/udev/rules.d/*realsense* 2>/dev/null | grep -E "hidraw|HID|0b3a|8086" | head -10
