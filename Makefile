SHELL := /bin/bash

.PHONY: build up down logs validate topics shell unbind-usb install-udev

build:
	sudo docker compose build 2>&1 | tee /tmp/rs-build2.log
	@echo ""
	@echo "Build log: /tmp/rs-build2.log"

# Unbind kernel drivereket a RealSense USB interface-ekről
# RSUSB backend (libusb) nem tud megnyitni interface-t ha uvcvideo/usbhid fogja
unbind-usb:
	@echo "── RealSense USB kernel driver unbind ──"
	@for dev in /sys/bus/usb/devices/*/; do \
		if grep -q "8086" "$$dev/idVendor" 2>/dev/null && grep -q "0b3a" "$$dev/idProduct" 2>/dev/null; then \
			for intf in $$dev*/; do \
				if [ -f "$$intf/bInterfaceNumber" ]; then \
					drv=$$(basename "$$(readlink "$$intf/driver" 2>/dev/null)" 2>/dev/null); \
					if [ -n "$$drv" ] && [ "$$drv" != "." ]; then \
						intf_id=$$(basename "$$intf"); \
						echo "  Unbind $$drv from $$intf_id"; \
						echo "$$intf_id" | sudo tee /sys/bus/usb/drivers/$$drv/unbind > /dev/null 2>&1 || true; \
					fi; \
				fi; \
			done; \
		fi; \
	done
	@echo "  Kész."

up: unbind-usb
	sudo docker compose up -d

down:
	sudo docker compose stop

logs:
	sudo docker compose logs -f ros2-realsense

RS_ROS := . /opt/ros/jazzy/install/setup.sh && . /opt/realsense_ws/install/setup.sh

validate:
	@echo "── RealSense validálás ──"
	@echo "1) Container logok (utolsó 20 sor):"
	@sudo docker compose logs --tail=20 ros2-realsense
	@echo ""
	@echo "2) RealSense topicok:"
	@sudo docker compose exec ros2-realsense bash -c \
		'$(RS_ROS) && ros2 topic list 2>/dev/null | grep -i camera || echo "NINCS camera topic"'
	@echo ""
	@echo "3) IMU Hz (10s):"
	@sudo docker compose exec ros2-realsense bash -c \
		'$(RS_ROS) && timeout 10 ros2 topic hz /camera/camera/imu --window 5 --qos-reliability best_effort 2>&1; true'

topics:
	sudo docker compose exec ros2-realsense bash -c \
		'$(RS_ROS) && ros2 topic list'

# Persistent udev rule: auto-unbind uvcvideo/usbhid RealSense-ről plug/reset után
install-udev:
	@echo "── udev rules telepítés ──"
	sudo cp 99-realsense-unbind.rules /etc/udev/rules.d/
	sudo udevadm control --reload-rules
	sudo udevadm trigger
	@echo "Kész. uvcvideo/usbhid többé nem bindol RealSense-re."

shell:
	sudo docker compose exec ros2-realsense bash
