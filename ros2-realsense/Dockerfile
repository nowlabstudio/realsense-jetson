# ROS2 Jazzy + realsense2_camera node
# Ubuntu 24.04 (Noble) | librealsense forrásból fordítva RSUSB backendel
#
# MIÉRT FORRÁSBÓL:
#   A ros-jazzy-librealsense2 apt csomag arm64-en törött HID/IMU támogatással
#   érkezik. A forrásból fordított verzió (FORCE_RSUSB_BACKEND=ON) teljes
#   IMU hozzáférést biztosít Docker containerben kernel modul nélkül.
#
# VERZIÓ: 2.56.4 — megegyezik a ros-jazzy-realsense2-camera apt csomag által
#   elvárt verzióval, így nincs "running with different librealsense version" warning.
#
# Build: docker compose build ros2-realsense
# Várható build idő: ~30-45 perc (ARM64, 6 mag)

# ─── Stage 1: librealsense fordítása forrásból ────────────────────────────────
FROM ubuntu:24.04 AS librealsense-builder

ARG LIBREALSENSE_VERSION=v2.56.4
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git pkg-config \
    ca-certificates curl \
    libusb-1.0-0-dev libudev-dev libssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone \
    --depth 1 \
    --branch ${LIBREALSENSE_VERSION} \
    https://github.com/realsenseai/librealsense.git \
    /opt/librealsense

RUN cmake \
    -S /opt/librealsense \
    -B /opt/librealsense/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DFORCE_RSUSB_BACKEND=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_GRAPHICAL_EXAMPLES=OFF \
    -DBUILD_TOOLS=ON \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_UNITY_BINDINGS=OFF \
    -DBUILD_WITH_CUDA=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX=/opt/rs-install

RUN cmake --build /opt/librealsense/build \
    --config Release \
    --parallel $(nproc) \
    && cmake --install /opt/librealsense/build

# ─── Stage 2: ROS2 Jazzy runtime ──────────────────────────────────────────────
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all,compute,video,utility

# Alap csomagok + ROS2 Jazzy repo
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg2 lsb-release ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    && curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
       | gpg --dearmor -o /etc/apt/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/ros-archive-keyring.gpg] \
       http://packages.ros.org/ros2/ubuntu noble main" \
       | tee /etc/apt/sources.list.d/ros2.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       ros-jazzy-ros-base \
       ros-jazzy-realsense2-camera \
       ros-jazzy-realsense2-description \
       ros-jazzy-image-transport \
       ros-jazzy-cv-bridge \
       ros-jazzy-tf2-ros \
       ros-jazzy-diagnostic-updater \
       python3-colcon-common-extensions \
       python3-rosdep \
       libusb-1.0-0 libudev1 \
    && rm -rf /var/lib/apt/lists/*

# A forrásból fordított librealsense felülírja a ros-jazzy-librealsense2 apt csomagot.
# A ROS camera node librealsense2.so.2.56 SONAME-t keres — a fordított 2.56.4
# azonos verzió, így sem ABI-eltérés, sem verziós warning nem keletkezik.
COPY --from=librealsense-builder /opt/rs-install/lib/librealsense2.so* \
    /opt/ros/jazzy/lib/aarch64-linux-gnu/
RUN ldconfig

COPY ros2-realsense/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["ros2", "launch", "realsense2_camera", "rs_launch.py", \
     "enable_rgbd:=true", \
     "enable_sync:=true", \
     "align_depth.enable:=true", \
     "enable_color:=true", \
     "enable_depth:=true", \
     "enable_accel:=true", \
     "enable_gyro:=true", \
     "unite_imu_method:=2", \
     "accel_fps:=250", \
     "gyro_fps:=400", \
     "pointcloud.enable:=true", \
     "depth_module.depth_profile:=640x480x30", \
     "rgb_camera.color_profile:=1280x720x30"]
