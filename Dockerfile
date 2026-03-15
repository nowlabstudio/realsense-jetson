# RealSense D435i — Jetson-optimalizált image
# Base: dustynv/ros:jazzy-ros-base-r36.4.0-cu128-24.04
#   - Jetson Orin Nano + JetPack 6.x (L4T r36.x) kompatibilis
#   - CUDA, cuDNN, TensorRT előre telepítve
#   - NVIDIA Jetson AI lab által karbantartott, publikus Docker Hub image
#
# librealsense RSUSB backenddel (forrásból):
#   - L4T kernel nem tartalmazza a hid_sensor_custom modult → kernel backend nem működik
#   - RSUSB = userspace libusb, kernel-független, ez a standard Jetson megközelítés
#   - Minden funkció elérhető: depth, stereo IR, IMU, HW sync
#
# Build: docker compose build
# Várható build idő: ~20-30 perc (librealsense + realsense-ros forrásból)

ARG BASE_IMAGE=dustynv/ros:jazzy-ros-base-r36.4.0-cu128-24.04
FROM ${BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive

# ── 1. ROS2 apt kulcs + build függőségek ──────────────────────────────────────
# DUSTYNV WORKAROUNDS:
#   --force-overwrite: dustynv NVIDIA OpenCV 4.11 ↔ apt libopencv-*-dev 4.6 dpkg ütközés
#   Teljes ROS2 dep lista: a dustynv base forrásból buildelt ROS2-t tartalmaz,
#   ami NEM tartalmazza az összes ros-jazzy-* csomagot (pl. std_srvs, lifecycle, stb.)
#   Ezeket apt-vel pótoljuk — a Step 3-ban CMAKE_PREFIX_PATH biztosítja a megtalálást
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && apt-get update \
    && apt-get -o Dpkg::Options::="--force-overwrite" \
        install -y --no-install-recommends \
        git cmake build-essential pkg-config \
        libusb-1.0-0-dev libssl-dev \
        python3-colcon-common-extensions \
        libeigen3-dev \
        ros-jazzy-rosidl-default-generators \
        ros-jazzy-rosidl-default-runtime \
        ros-jazzy-cv-bridge \
        ros-jazzy-image-transport \
        ros-jazzy-diagnostic-updater \
        ros-jazzy-launch-ros \
        ros-jazzy-lifecycle-msgs \
        ros-jazzy-nav-msgs \
        ros-jazzy-rclcpp-components \
        ros-jazzy-rclcpp-lifecycle \
        ros-jazzy-std-srvs \
        ros-jazzy-tf2-ros \
        ros-jazzy-xacro \
    && rm -rf /var/lib/apt/lists/*

# ── 2. librealsense forrásból — RSUSB backend ────────────────────────────────
ARG LIBREALSENSE_VERSION=v2.56.4
RUN git clone --depth 1 -b ${LIBREALSENSE_VERSION} \
        https://github.com/IntelRealSense/librealsense.git /tmp/librealsense \
    && cd /tmp/librealsense && mkdir build && cd build \
    && cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DFORCE_RSUSB_BACKEND=ON \
        -DBUILD_EXAMPLES=OFF \
        -DBUILD_GRAPHICAL_EXAMPLES=OFF \
        -DBUILD_PYTHON_BINDINGS=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
    && make -j$(nproc) \
    && make install \
    && ldconfig \
    && rm -rf /tmp/librealsense

# ── 3. realsense-ros wrapper forrásból (colcon overlay) ───────────────────────
# CMAKE_PREFIX_PATH: dustynv setup.sh a forrásból buildelt ROS2-t source-olja,
# de az apt-vel telepített csomagok /opt/ros/jazzy/-ben vannak — ez kézzel kell
ARG REALSENSE_ROS_VERSION=4.56.4
RUN mkdir -p /opt/realsense_ws/src \
    && git clone --depth 1 -b ${REALSENSE_ROS_VERSION} \
        https://github.com/IntelRealSense/realsense-ros.git \
        /opt/realsense_ws/src/realsense-ros \
    && . /opt/ros/jazzy/setup.sh \
    && cd /opt/realsense_ws \
    && colcon build --cmake-args \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="/opt/ros/jazzy" \
    && rm -rf /opt/realsense_ws/build /opt/realsense_ws/log \
    && rm -rf /opt/realsense_ws/src

# dustynv: ros2 CLI → /opt/ros/jazzy/install/bin/ (NEM /opt/ros/jazzy/bin/)
ENV PATH="/opt/ros/jazzy/install/bin:${PATH}"

CMD ["bash", "-c", "source /opt/ros/jazzy/setup.bash && source /opt/realsense_ws/install/setup.bash && ros2 launch realsense2_camera rs_launch.py"]
