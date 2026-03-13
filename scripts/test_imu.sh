#!/bin/bash
docker compose -f ~/realsense-docker/docker-compose.yml up -d --force-recreate ros2-realsense
docker exec -it ros2_realsense bash -c "source /opt/ros/jazzy/setup.bash && ros2 launch realsense2_camera rs_launch.py enable_accel:=true enable_gyro:=true unite_imu_method:=2"
