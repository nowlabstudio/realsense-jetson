# ROS2 Jazzy + realsense2_camera node
# Ubuntu 24.04 (Noble) | librealsense + realsense2_camera forrásból
#
# MIÉRT FORRÁSBÓL (mindkettő):
#   librealsense: FORCE_RSUSB_BACKEND=ON (kernel modul nélkül Docker-ben)
#                 BUILD_GLSL_EXTENSIONS=ON (GPU gyorsítás előfeltétele)
#   realsense2_camera: az apt csomag nem tartalmaz OpenMP-t és GLSL-t —
#                      colcon build szükséges ezek engedélyezéséhez.
#
# Teljesítmény optimalizációk:
#   - librealsense:        -O3, -march=native, LTO, -fno-plt, GLSL extensions
#   - realsense2_camera:   OpenMP (multi-core depth/filter pipeline)
#                          GLSL GPU gyorsítás (PointCloud + Colorizer, default: OFF)
#
# GLSL bekapcsolás (docker-compose command-ban):
#   accelerate_gpu_with_glsl:=true
#   (Headless Jetson-on EGL surfaceless context-et használ)
#
# Build: docker compose build ros2-realsense
# Várható build idő: ~50-70 perc (ARM64, 6 mag)

# ─── Stage 1: librealsense fordítása forrásból ────────────────────────────────
FROM ubuntu:24.04 AS librealsense-builder

ARG LIBREALSENSE_VERSION=v2.56.4
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake git pkg-config \
    ca-certificates curl \
    libusb-1.0-0-dev libudev-dev libssl-dev \
    # GLSL extensions build deps (librealsense2-glsl.so előállításához)
    libgl1-mesa-dev \
    libglfw3-dev \
    libgles2-mesa-dev \
    libegl1-mesa-dev \
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
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=native -fno-plt" \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=native -fno-plt" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DFORCE_RSUSB_BACKEND=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_GRAPHICAL_EXAMPLES=OFF \
    -DBUILD_TOOLS=ON \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_UNITY_BINDINGS=OFF \
    -DBUILD_WITH_CUDA=OFF \
    -DBUILD_GLSL_EXTENSIONS=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX=/opt/rs-install

RUN cmake --build /opt/librealsense/build \
    --config Release \
    --parallel $(nproc) \
    && cmake --install /opt/librealsense/build


# ─── Stage 2: realsense2_camera colcon builder ───────────────────────────────
FROM ubuntu:24.04 AS ros2-camera-builder

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
ENV CMAKE_PREFIX_PATH=/usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg2 ca-certificates git \
    && mkdir -p /etc/apt/keyrings \
    && curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
       | gpg --dearmor -o /etc/apt/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/ros-archive-keyring.gpg] \
       http://packages.ros.org/ros2/ubuntu noble main" \
       | tee /etc/apt/sources.list.d/ros2.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       ros-jazzy-ros-base \
       ros-jazzy-image-transport \
       ros-jazzy-cv-bridge \
       ros-jazzy-tf2-ros \
       ros-jazzy-diagnostic-updater \
       python3-colcon-common-extensions \
       # colcon-hoz kell: cmake + make + C++ compiler
       build-essential cmake \
       # OpenMP runtime (fordításhoz és futáshoz egyaránt kell)
       libgomp1 \
       # GLSL build deps
       libgl1-mesa-dev \
       libgles2-mesa-dev \
       libegl1-mesa-dev \
       libusb-1.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Custom librealsense (RSUSB + GLSL extensions) — find_package(realsense2) ezt találja
COPY --from=librealsense-builder /opt/rs-install /usr/local
RUN ldconfig

# realsense-ros forrás — csak a szükséges package-ek lesznek fordítva
RUN git clone \
    --depth 1 \
    --branch ros2-development \
    https://github.com/realsenseai/realsense-ros.git \
    /opt/realsense-ros

# colcon build:
#   BUILD_WITH_OPENMP=ON          → multi-core depth/filter processing
#   BUILD_ACCELERATE_GPU_WITH_GLSL=ON → GPU PointCloud + Colorizer (futáskor kapcsolható)
#   realsense2_rgbd_plugin kihagyva  → RViz2 plugin, headless-en nem kell
#   realsense2_ros_mqtt_bridge kihagyva → Zenoh váltja fel
RUN . /opt/ros/jazzy/setup.sh && \
    cd /opt/realsense-ros && \
    colcon build \
        --packages-select \
            realsense2_camera_msgs \
            realsense2_camera \
            realsense2_description \
        --merge-install \
        --install-base /opt/ros2-camera-install \
        --cmake-args \
            -DCMAKE_BUILD_TYPE=Release \
            "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -march=native -fno-plt" \
            -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
            -DBUILD_WITH_OPENMP=ON \
            -DBUILD_ACCELERATE_GPU_WITH_GLSL=OFF


# ─── Stage 3: Runtime ─────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
ENV NVIDIA_VISIBLE_DEVICES=all
# graphics: GLSL/EGL GPU gyorsításhoz szükséges
ENV NVIDIA_DRIVER_CAPABILITIES=all,compute,video,utility,graphics

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl gnupg2 ca-certificates \
    && mkdir -p /etc/apt/keyrings \
    && curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
       | gpg --dearmor -o /etc/apt/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/ros-archive-keyring.gpg] \
       http://packages.ros.org/ros2/ubuntu noble main" \
       | tee /etc/apt/sources.list.d/ros2.list \
    && apt-get update && apt-get install -y --no-install-recommends \
       ros-jazzy-ros-base \
       ros-jazzy-image-transport \
       ros-jazzy-cv-bridge \
       ros-jazzy-tf2-ros \
       ros-jazzy-diagnostic-updater \
       libusb-1.0-0 libudev1 \
       # OpenMP runtime
       libgomp1 \
       # OpenGL/EGL runtime (GLSL GPU gyorsításhoz — EGL surfaceless headless-en)
       libgl1 \
       libgles2 \
       libegl1 \
    && rm -rf /var/lib/apt/lists/*

# librealsense runtime: alap .so + GLSL extension .so
COPY --from=librealsense-builder /opt/rs-install/lib/librealsense2*.so* /usr/local/lib/
RUN ldconfig

# colcon workspace: realsense2_camera_msgs + realsense2_camera + realsense2_description
COPY --from=ros2-camera-builder /opt/ros2-camera-install /opt/ros2-camera-install

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
     "rgb_camera.color_profile:=1280x720x30", \
     "accelerate_gpu_with_glsl:=false"]
