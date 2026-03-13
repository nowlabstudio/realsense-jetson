#!/bin/bash
echo "=== librealsense2 shared lib location ==="
docker exec ros2_realsense find /usr /opt/ros -name "librealsense2.so*" 2>/dev/null

echo ""
echo "=== librealsense2 linked against libudev? (V4L2 backend indicator) ==="
docker exec ros2_realsense bash -c "ldd \$(find /usr /opt/ros -name 'librealsense2.so*' 2>/dev/null | head -1) 2>/dev/null | grep -E 'udev|usb|hid'"

echo ""
echo "=== librealsense2 cmake config (backend info) ==="
docker exec ros2_realsense find /usr /opt/ros -name "realsense2Config.cmake" -o -name "realsense2-config.cmake" 2>/dev/null | xargs grep -i "rsusb\|v4l\|backend\|hid" 2>/dev/null | head -20

echo ""
echo "=== HID symbols in librealsense2? ==="
docker exec ros2_realsense bash -c "nm -D \$(find /usr /opt/ros -name 'librealsense2.so*' 2>/dev/null | head -1) 2>/dev/null | grep -i 'hid' | head -10"

echo ""
echo "=== USB speed of camera on host ==="
lsusb -v -d 8086:0b3a 2>/dev/null | grep -E "bcdUSB|idProduct|iProduct|bMaxPacketSize"
