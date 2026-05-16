# Isaac ROS 3.2 Humble Heterogén Stack — Reprodukciós Setup

**Cél:** GPU-accelerated NITROS pointcloud D435i RealSense kameráról egy ROS 2 Jazzy fő-stackbe, JetPack 6.x (L4T r36.x) Orin Nano-n, az NVIDIA Isaac ROS hivatalos disztribúciójával.

**Architektúra:** **Humble container** (Isaac 3.2.x + NITROS) **publish-ol** → **DDS cross-distro bridge** (CycloneDDS) → **Jazzy container** (Nav2 / fő-stack) **subscribe-ol**.

**Időhorizont:** 2026 H2 (JetPack 7.2 megjelenéséig). JP7.2 után az Isaac 4.x natív Orin-Jazzy ágra váltható, akkor a heterogén-stack megszűnhet.

**Validált környezet (2026-05-16):**
- Hardware: Jetson Orin Nano 8 GB
- OS: Ubuntu 22.04 (L4T R36.4.3)
- Camera: Intel RealSense D435i, FW 5.17.0.10
- Pipeline rate: `/camera/depth/points` **30.13 Hz Humble-side**, **30.02 Hz Jazzy-side cross-distro**
- Latency: ~295 ms worst-case capture→cmd_vel
- RAM: 248 MB / 8 GB stabil
- Restart count: 0 / 5 perc stress

---

## 1. Stratégiai döntések — miért így

### 1.1 Miért Humble container Jazzy host alatt? (Opció E)

10-agent kompatibilitás-audit bizonyította:
- **Isaac ROS 4.x (Jazzy) Orin Nano-n NEM működik** — empirikusan validált: Tegra-driver-bind r36 vs r38, GXF SASS-only sm_10x, CUDA 13 vs 12.6
- **NVIDIA hivatalos pozíció**: Orin Nano → Isaac ROS 3.x + Humble + JP6 (a 3.2 az utolsó támogatott verzió)
- **Forrás-build NEM lehetséges**: GXF binárisok closed-source, csak NVIDIA aarch64-thor target

### 1.2 Miért B.3 build-stratégia (L4T-jetpack base + apt overlay)?

A `nvcr.io/nvidia/isaac/ros:aarch64-ros2_humble` 2026-05-16 állapotban csak hash-tagged immutable release-ekkel jön + NGC login + EULA-elfogadás kell.

A `nvcr.io/nvidia/l4t-jetpack:r36.4.0` **PUBLIC** + az Isaac apt repo (`isaac.download.nvidia.com/isaac-ros/release-3`) **PUBLIC** → ugyanaz a funkcionalitás NGC friction nélkül, kontrolláltabb Dockerfile.

### 1.3 KRITIKUS architektúra-szabályok

1. **Humble container CSAK publish-ol**, NEM subscribe-ol Jazzy-topicra (OOM-risk: `rmw_fastrtps#797`)
2. **NITROS pipeline self-contained**: a `realsense2_camera_node` + `ConvertMetricNode` + `PointCloudXyzNode` UGYANABBAN a `ComposableNodeContainer`-ben (zero-copy GPU-buffer)
3. **TF-frame-nevek egyezzenek** a Jazzy URDF-fel (`camera_link`, `camera_color_optical_frame` stb.)
4. **Egyirányú DDS-flow** (Humble→Jazzy), bidirectional NEM ajánlott

---

## 2. Verzió-mátrix

| Komponens | Pin | Forrás |
|---|---|---|
| HostOS | Ubuntu 22.04 (L4T R36.4.x, JP 6.x) | Jetson SDK Manager |
| Tegra-driver | r36, CUDA 12.6 | L4T base |
| **Container base** | `nvcr.io/nvidia/l4t-jetpack:r36.4.0` PUBLIC | NVIDIA NGC |
| ROS 2 | Humble — `ros-humble-ros-base` apt | packages.ros.org/ros2/ubuntu jammy main |
| **librealsense** | **v2.56.4** (source build, RSUSB) | github.com/IntelRealSense/librealsense |
| **realsense-ros fork** | **release/4.51.1-isaac** (colcon overlay) | github.com/NVIDIA-ISAAC-ROS/realsense-ros |
| Isaac ROS apt | `release-3` repo, **release-3.0 component** (3.2.x csomagok) | isaac.download.nvidia.com/isaac-ros/release-3 |
| CV-CUDA | v0.16.0 cuda12 aarch64 (lib only, .deb) | github.com/CVCUDA/CV-CUDA/releases |
| D435i firmware | 5.17.0.10 (vagy újabb) | Intel RealSense Viewer |
| CycloneDDS | 0.10.x (Jazzy + Humble egyező) | apt |

### 2.1 Disk + RAM budget

- L4T-jetpack base: ~15.5 GB
- Final image (`ros2-realsense:humble-isaac-3.2-talicska`): **~17.2 GB**
- Build cache + intermediate: kb 5-7 GB → minimum **25 GB szabad** a build előtt
- RAM idle: Humble container ~1.5-2 GB + Jazzy stack ~2.7 GB + HostOS ~1 GB = ~5-6 GB / 8 GB
- Konzervatív minimum: 4 GB szabad idle RAM build idejére

---

## 3. Host előfeltételek

### 3.1 Kernel UDP buffer (KRITIKUS — különben 80% drop!)

A 3.7 MB-os PointCloud2 üzeneteket fragmentálja a UDP. Default `net.core.rmem_max=1MB` túl kicsi → drop. **Perzisztens beállítás:**

```bash
sudo tee /etc/sysctl.d/99-ros2-dds-buffer.conf > /dev/null <<'EOF'
# ROS 2 cyclonedds large-message tuning (Isaac Humble↔Jazzy cross-distro
# PointCloud2 3.7 MB). 1 MB rmem_max → buffer overflow → 80% drop a
# /camera/depth/points-on. 64 MB rmem/wmem ad 4-5 üzenet egyidejű pufferelést.
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=8388608
net.core.wmem_default=8388608
EOF

# Runtime aktiválás (reboot helyett)
sudo sysctl -w net.core.rmem_max=67108864
sudo sysctl -w net.core.wmem_max=67108864
sudo sysctl -w net.core.rmem_default=8388608
sudo sysctl -w net.core.wmem_default=8388608

# Verify
sysctl net.core.rmem_max net.core.wmem_max
```

### 3.2 udev rules (libusb permission)

```bash
# /etc/udev/rules.d/99-realsense-libusb.rules
SUBSYSTEM=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b3a", MODE="0666", GROUP="plugdev"
SUBSYSTEM=="usb", ATTRS{idVendor}=="8086", ATTRS{idProduct}=="0b07", MODE="0666", GROUP="plugdev"

sudo udevadm control --reload && sudo udevadm trigger
```

### 3.3 Docker daemon nvidia runtime

```bash
# /etc/docker/daemon.json
{
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "nvidia-container-runtime",
      "runtimeArgs": []
    }
  }
}
sudo systemctl restart docker
```

---

## 4. Dockerfile — lépés-lépés magyarázattal

A teljes `Dockerfile.isaac-humble` lépéseit tagolva, mindegyikhez **a 7 H5-iteráció failure-tanulságával**.

### 4.1 Base + build deps

```dockerfile
FROM nvcr.io/nvidia/l4t-jetpack:r36.4.0
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        curl gnupg lsb-release ca-certificates \
        git cmake build-essential pkg-config \
        libusb-1.0-0-dev libssl-dev libudev-dev \
    && rm -rf /var/lib/apt/lists/*
```

**Why l4t-jetpack:** CUDA 12.6 + TensorRT + cuDNN előre telepítve. PUBLIC, NGC auth nem kell.

### 4.2 ROS 2 + Isaac ROS apt repok

```dockerfile
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=arm64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main" \
        > /etc/apt/sources.list.d/ros2.list \
    && curl -sSL https://isaac.download.nvidia.com/isaac-ros/repos.key \
        | gpg --dearmor -o /usr/share/keyrings/isaac-ros-archive-keyring.gpg \
    && echo "deb [arch=arm64 signed-by=/usr/share/keyrings/isaac-ros-archive-keyring.gpg] https://isaac.download.nvidia.com/isaac-ros/release-3 jammy release-3.0" \
        > /etc/apt/sources.list.d/isaac-ros.list
```

**KRITIKUS — Isaac repo komponens-név**: `release-3.0` (NEM `release-3.2`!). Az InRelease deklarálja: `legacy-release-3.0`, `legacy-release-3.1`, **`release-3.0`** ← AKTUÁLIS 3.2.x csomagok ezen a komponensen.

### 4.3 APT csomagok — KÖZPONTI tanulság: NE installáld a realsense2-camera-t

```dockerfile
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ros-humble-ros-base \
        ros-humble-rmw-cyclonedds-cpp \
        ros-humble-isaac-ros-realsense \
        ros-humble-isaac-ros-depth-image-proc \
        ros-humble-isaac-ros-image-proc \
        ros-humble-isaac-ros-managed-nitros \
        ros-humble-isaac-ros-examples \
        ros-humble-rclcpp-components \
        ros-humble-diagnostic-updater \
        ros-humble-cv-bridge \
        ros-humble-image-transport \
        python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*
```

**FAIL-MODE (H5-v7)** ha telepíted a `ros-humble-realsense2-camera`-t:
- Az apt-csomag DEPENDS-eli a `ros-humble-librealsense2 2.57.7`-et
- A 2.57.7 install létrehozza a `/opt/ros/humble/lib/aarch64-linux-gnu/cmake/realsense2/realsense2Targets.cmake`-et
- A későbbi 2.56.4 source install **NEM tudja felülírni** ezt a CMake target file-t (a `Targets-release.cmake`-et igen, de a fő `Targets.cmake`-et nem)
- Eredmény: colcon `find_package(realsense2)` exit 1: *"but not all the files it references"* (2.57.7 `.so`-kra mutat amiket nincs)

**Megoldás**: az Isaac fork colcon build (6. lépés) overlay-ben generálja a saját `realsense2_camera` + `realsense2_camera_msgs` package-eket. A `ros-humble-isaac-ros-realsense` apt-csomag CSAK 57 KB launch fragment, NEM dep-eli a realsense2-camera-t (`apt-cache depends` verified).

### 4.4 librealsense 2.56.4 source build (RSUSB backend)

```dockerfile
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
        -DCMAKE_INSTALL_PREFIX=/opt/ros/humble \
        -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/librealsense
```

**FAIL-MODE (H5-v3)**: Standard ROS apt `ros-humble-librealsense2` (UVC kernel backend) **NEM detektálja a D435i-t** Jetsonon (`No RealSense devices were found`). Ok: L4T kernel hiányol a `hid_sensor_custom` modult.

**FAIL-MODE (H5-v6, ROOT CAUSE)**: librealsense **2.55.1** RSUSB build **instabil JP6 r36.4-on** — `control_transfer EAGAIN` flood, 0 frame jön a stream-nyitásnál. A **2.56.4 stabil** (Jazzy stack baseline 2.56.4-tel 30 Hz depth-et publikál ugyanazon a kamerán).

**Verzió-szabály**: az Isaac fork 4.51.1-isaac CMakeLists `find_package(realsense2 2.51.1)` = MINIMUM 2.51.1 → 2.56.4-tel forward-kompatibilis.

**Install prefix `/opt/ros/humble`** (NEM `/usr/local`): az Isaac fork colcon-build a `/opt/ros/humble` CMake config-ot találja meg ELŐSZÖR a CMAKE_PREFIX_PATH-ban.

### 4.5 Verify librealsense + ld.so.conf

```dockerfile
RUN echo "/opt/ros/humble/lib/aarch64-linux-gnu" > /etc/ld.so.conf.d/ros-humble.conf \
    && ldconfig \
    && ls -la /opt/ros/humble/lib/aarch64-linux-gnu/librealsense2.so* \
    && ls /opt/ros/humble/lib/aarch64-linux-gnu/cmake/realsense2/ \
    && ldconfig -p | grep librealsense2
```

**FAIL-MODE (build-time `rs-fw-update` test exit 127)**: a `/opt/ros/humble/lib/aarch64-linux-gnu` NEM alapértelmezett ld.so path → buildtime `rs-fw-update` `cannot open shared object file: librealsense2.so.2.56`. Runtime-ban a ROS setup.bash hozzáadja az `LD_LIBRARY_PATH`-hoz, de buildtime-ban explicit `ld.so.conf.d` entry kell.

### 4.6 Isaac fork realsense-ros colcon build

```dockerfile
ARG ISAAC_REALSENSE_ROS_BRANCH=release/4.51.1-isaac
RUN mkdir -p /opt/realsense_ws/src \
    && git clone --depth 1 -b ${ISAAC_REALSENSE_ROS_BRANCH} \
        https://github.com/NVIDIA-ISAAC-ROS/realsense-ros.git \
        /opt/realsense_ws/src/realsense-ros \
    && cd /opt/realsense_ws \
    && bash -c "source /opt/ros/humble/setup.bash \
        && colcon build --merge-install --install-base /opt/realsense_ws/install \
            --cmake-args -DCMAKE_BUILD_TYPE=Release" \
    && rm -rf /opt/realsense_ws/build /opt/realsense_ws/log
```

**FAIL-MODE (H5-v4)**: A standard apt `ros-humble-realsense2-camera` 4.57.7 NEM NITROS-aware. A NITROS `PointCloudXyzNode` `nitros_image_32FC1`-et vár, az apt-csomag csak `sensor_msgs/Image`-t publikál → `GXF_INVALID_DATA_FORMAT`. Az **Isaac fork `release/4.51.1-isaac`** NITROS-natívan publikál.

**FAIL-MODE (H5-v5)**: Ha a CMAKE_INSTALL_PREFIX `/usr/local` (régi terv), a colcon-build a `/opt/ros/humble` CMake config-ot találja meg ELŐSZÖR (apt 2.57.7) → fork 2.57.7-tel build-elt, NEM 2.55.1-tel. Ezért kell az install prefix `/opt/ros/humble`.

### 4.7 CV-CUDA library bake (NITROS ConvertMetricNode dep)

```dockerfile
ARG CVCUDA_VERSION=0.16.0
RUN curl -sLO https://github.com/CVCUDA/CV-CUDA/releases/download/v${CVCUDA_VERSION}/cvcuda-lib-${CVCUDA_VERSION}-cuda12-aarch64-linux.deb \
    && dpkg -i cvcuda-lib-${CVCUDA_VERSION}-cuda12-aarch64-linux.deb \
    && rm -f cvcuda-lib-${CVCUDA_VERSION}-cuda12-aarch64-linux.deb \
    && ldconfig \
    && ldconfig -p | grep cvcuda
```

**FAIL-MODE (runtime)**: A `ros-humble-isaac-ros-depth-image-proc` NITROS pipeline-ja runtime `libcvcuda.so.0`-t kér. Az Isaac apt repo **NEM tartalmazza** — külön telepítés szükséges GitHub release-ről.

**Verzió-mátrix**: CV-CUDA v0.16.0 → CUDA 12 (matches l4t-jetpack r36.4.0 CUDA 12.6) → aarch64 (matches Orin Nano).

### 4.8 Talicska launch + config + CMD

```dockerfile
RUN mkdir -p /opt/talicska/launch /opt/talicska/config
ENV PATH="/opt/ros/humble/bin:${PATH}"
ENV ROS_VERSION=2
ENV ROS_DISTRO=humble
WORKDIR /opt/talicska

CMD ["bash", "-c", "source /opt/ros/humble/setup.bash && source /opt/realsense_ws/install/setup.bash && ros2 launch /opt/talicska/launch/isaac_realsense.launch.py"]
```

**Source-olási sorrend**: humble base → realsense_ws overlay. Az overlay precedence shadow-olja az apt-installt (ha vissza-tér).

---

## 5. docker-compose.isaac-humble.yml

```yaml
services:
  ros2-realsense-isaac:
    image: ros2-realsense:humble-isaac-3.2-talicska
    build:
      context: .
      dockerfile: Dockerfile.isaac-humble
      network: host  # buildkit DNS resolve fix
    container_name: ros2_realsense_isaac
    runtime: nvidia
    network_mode: host
    ipc: host
    restart: unless-stopped
    privileged: true
    shm_size: 2gb    # NITROS zero-copy buffers
    devices:
      - /dev/bus/usb:/dev/bus/usb
      - /dev/video0:/dev/video0
      - /dev/video1:/dev/video1
      # ... video2-5, hidraw0-6 (D435i exposes több device-t)
    volumes:
      - /run/udev:/run/udev:ro
      - ./cyclonedds.xml:/cyclonedds.xml:ro
      - ./launch:/opt/talicska/launch:ro
      - ./realsense_params.isaac.yaml:/opt/talicska/config/realsense_params.yaml:ro
    group_add:
      - video
      - plugdev
      - "101"    # input group (hidraw)
    ulimits:
      rtprio: 99       # USB transfer threadek RT prio
      memlock: -1
    environment:
      - ROS_DOMAIN_ID=0
      - RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
      - CYCLONEDDS_URI=file:///cyclonedds.xml
      - NVIDIA_VISIBLE_DEVICES=all
```

**FAIL-MODE (H5-v1, buildkit DNS)**: `docker compose build` a bridge network namespace-ben **DNS-szegregált** → `ports.ubuntu.com` "Temporary failure resolving" → 20+ perc apt timeout. **Fix**: `build.network: host` a compose-ban.

**`shm_size: 2gb`**: NITROS zero-copy buffers szükséglet.

**`privileged: true` + `group_add: ["101"]`**: a hidraw device-okhoz hozzáférés a librealsense USB-controlhez.

---

## 6. cyclonedds.xml — buffer tune KRITIKUS

```xml
<?xml version="1.0" encoding="UTF-8" ?>
<CycloneDDS>
  <Domain>
    <General>
      <Interfaces>
        <NetworkInterface name="lo"    priority="default" multicast="false"/>
        <NetworkInterface name="wlan0" priority="default" multicast="false"/>
      </Interfaces>
      <AllowMulticast>false</AllowMulticast>
      <MaxMessageSize>65500B</MaxMessageSize>
    </General>

    <!-- NITROS PointCloud2 3.7 MB cross-distro Humble↔Jazzy fix -->
    <Internal>
      <SocketReceiveBufferSize min="2MiB" max="16MiB"/>
      <SocketSendBufferSize min="2MiB" max="16MiB"/>
    </Internal>

    <Discovery>
      <ParticipantIndex>auto</ParticipantIndex>
      <MaxAutoParticipantIndex>64</MaxAutoParticipantIndex>
      <Peers>
        <Peer address="127.0.0.1"/>
      </Peers>
    </Discovery>
  </Domain>
</CycloneDDS>
```

**FAIL-MODE (H7-cross-distro fix)**: a 3.7 MB-os PointCloud2 üzenet a default 1 MB UDP buffer-en **NEM fér el** → fragment-loss → RELIABLE QoS retransmit-storm → **backpressure visszafelé a publisher-re is** (Humble 30 Hz → 13.9 Hz, Jazzy 3 Hz, mért).

**KRITIKUS XML syntax**: `min=` és `max=` **ATTRIBUTE-ok**, NEM element-content. Az `<SocketReceiveBufferSize>16MiB</SocketReceiveBufferSize>` syntax **FAIL-el** "no data expected" error-ral, és az egész CycloneDDS init meghal → minden ROS node restart-loop.

**Discovery `<Peer address="127.0.0.1"/>`**: cross-RMW (FastDDS microros_agent + CycloneDDS nodes) explicit unicast discovery loopback-en, multicast nélkül.

---

## 7. launch/isaac_realsense.launch.py

A working launch a NVIDIA stock minta backportja (`isaac_ros_examples` aggregator-fragmentek alapján).

**Key delták a "naive" launch-hoz képest:**

1. **Node name `realsense2_camera`** (NEM `'camera'`) — a NITROS managed_nitros publisher a node-nevet használja a topic-discovery-hez
2. **`parameters=[YAML_FILE]`** (NEM inline dict) — kontrollált paraméter-set
3. **Remappings**: `color/image_raw → image_rect`, `color/camera_info → camera_info_rect`
4. **`align_depth.enable: true`** — trigger-eli a `/aligned_depth_to_color/image_raw` NITROS-tagged publishert
5. **3 ComposableNode egyetlen container-ben**: realsense + convert_metric + point_cloud_xyz (zero-copy NITROS intra-process)

```python
"""Isaac NITROS RealSense launch — NVIDIA stock minta backportja."""

import os
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import LogInfo
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode


def generate_launch_description():
    # Bind-mountolt YAML override, fallback stock NVIDIA mintára
    realsense_config_file = '/opt/talicska/config/realsense_params.yaml'
    if not os.path.exists(realsense_config_file):
        realsense_config_file = os.path.join(
            get_package_share_directory('isaac_ros_realsense'),
            'config', 'realsense_mono_depth.yaml'
        )

    realsense_node = ComposableNode(
        package='realsense2_camera',
        plugin='realsense2_camera::RealSenseNodeFactory',
        name='realsense2_camera',
        namespace='',
        parameters=[realsense_config_file],
        remappings=[
            ('color/image_raw', 'image_rect'),
            ('color/camera_info', 'camera_info_rect'),
        ],
    )

    # Z16 mm uint16 → float32 m, NITROS-tagged
    convert_metric_node = ComposableNode(
        package='isaac_ros_depth_image_proc',
        plugin='nvidia::isaac_ros::depth_image_proc::ConvertMetricNode',
        name='convert_metric',
        remappings=[
            ('image_raw', '/aligned_depth_to_color/image_raw'),
            ('image', '/depth'),
        ],
    )

    # GPU NITROS pointcloud
    point_cloud_xyz_node = ComposableNode(
        package='isaac_ros_depth_image_proc',
        plugin='nvidia::isaac_ros::depth_image_proc::PointCloudXyzNode',
        name='point_cloud_xyz',
        remappings=[
            ('image_rect', '/depth'),
            ('camera_info', '/aligned_depth_to_color/camera_info'),
            ('points', '/camera/depth/points'),
        ],
    )

    container = ComposableNodeContainer(
        name='isaac_realsense_container',
        namespace='',
        package='rclcpp_components',
        executable='component_container_mt',
        composable_node_descriptions=[
            realsense_node,
            convert_metric_node,
            point_cloud_xyz_node,
        ],
        output='screen',
        emulate_tty=True,
    )

    return LaunchDescription([
        LogInfo(msg=('Starting Isaac NITROS RealSense pipeline')),
        container,
    ])
```

**FAIL-MODE (`use_intra_process_comms=True`)**: NE add hozzá az `extra_arguments=[{'use_intra_process_comms': True}]`-t a ComposableNode-okra! INKOMPATIBILIS a NITROS managed_nitros-szal — a NITROS-pipeline (convert_metric + point_cloud_xyz) NEM indul el, `/depth` és `/camera/depth/points` topicok eltűnnek. A NITROS managed_nitros saját zero-copy IPC-t használ, az rclcpp intra-process-szel ütközik.

---

## 8. realsense_params.isaac.yaml

Bind-mountolt override (image-rebuild nélkül módosítható):

```yaml
rgb_camera:
  profile: '640x480x30'
color_qos: "SYSTEM_DEFAULT"

depth_module:
  profile: '640x480x30'
  emitter_enabled: 1
  emitter_on_off: false
depth_qos: "SYSTEM_DEFAULT"
depth_info_qos: "SYSTEM_DEFAULT"

enable_infra1: false
enable_infra2: false

# IMU disable a "Motion Module force pause" hardware warning elkerüléséhez
# (depth-only pipeline a Nav2 VoxelLayer use-case-hez). VIO esetén enable!
enable_accel: false
enable_gyro: false

align_depth.enable: true
```

**VIO esetén** (cuVSLAM): `enable_infra1: true`, `enable_infra2: true`, `enable_accel: true`, `enable_gyro: true`, `unite_imu_method: 2`.

---

## 9. Build + Start

```bash
cd realsense-jetson/
docker compose -f docker-compose.isaac-humble.yml build ros2-realsense-isaac
# Build idő: ~25-30 perc Orin Nano 6-mag CPU-n első alkalommal
# Cache-elt rebuild (csak Dockerfile lépés-változás): ~5-10 perc

docker compose -f docker-compose.isaac-humble.yml up -d ros2-realsense-isaac
```

---

## 10. Validation

```bash
# Container Up + healthy
docker ps --filter "name=isaac" --format '{{.Names}}: {{.Status}}'
docker inspect ros2_realsense_isaac --format 'RestartCount: {{.RestartCount}}'

# Topic list (Humble-side)
docker exec ros2_realsense_isaac bash -c \
    "source /opt/ros/humble/setup.bash && ros2 topic list | grep -E 'points|depth'"

# Rate Humble-side
docker exec ros2_realsense_isaac bash -c \
    "source /opt/ros/humble/setup.bash && timeout 12 ros2 topic hz /camera/depth/points"
# Várt: 30 Hz stabil, std dev < 10 ms

# Rate Jazzy-side (cross-distro)
docker exec <jazzy_container> bash -c \
    "source /opt/ros/jazzy/setup.bash && timeout 12 ros2 topic hz /camera/depth/points"
# Várt: 30 Hz stabil (1:1 cross-distro)

# GPU activity (NITROS bizonyíték)
tegrastats --interval 1000 --logfile /tmp/gpu.log &
sleep 30; kill %1
grep -oE "GR3D_FREQ [0-9]+%" /tmp/gpu.log | sort -u
# Várt: peak 4%+ (NITROS GPU aktivitás bizonyíték)

# RAM
docker stats ros2_realsense_isaac --no-stream --format "{{.MemUsage}}"
# Várt: < 500 MB
```

---

## 11. Failure-mode összefoglaló (7 H5-iteráció)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| v1 | `apt-get update` timeout 20+ perc | buildkit bridge namespace DNS-szegregált | `build.network: host` compose-ban |
| v2 | Container Up → restart-loop, dlopen error | `librmw_cyclonedds_cpp.so` hiányzik | `ros-humble-rmw-cyclonedds-cpp` apt-csomag |
| v3 | "No RealSense devices were found" | Apt librealsense2 kernel UVC backend, `hid_sensor_custom` modul hiányzik Jetsonon | librealsense source build `FORCE_RSUSB_BACKEND=ON` |
| v4 | NITROS PointCloudXyz `GXF_INVALID_DATA_FORMAT` | Standard apt `realsense2_camera` NEM NITROS-aware, csak `sensor_msgs/Image` | Isaac fork `release/4.51.1-isaac` colcon overlay-ben |
| v5 | Fork 2.57.7-tel build-elt, NEM 2.55.1-tel | `-DCMAKE_INSTALL_PREFIX=/usr/local` után a colcon-build a `/opt/ros/humble` apt-féle CMake configot találta ELŐSZÖR | Source install prefix `/opt/ros/humble` |
| v6 | Kamera Up, "Open profile" OK, DE 0 frame, `control_transfer EAGAIN` flood | librealsense **2.55.1** RSUSB build instabil JP6 r36.4-on | **librealsense 2.56.4 bump** |
| v7 | colcon `find_package(realsense2)`: "but not all the files it references" | Apt `librealsense2` 2.57.7 cmake target `realsense2Targets.cmake` konfliktus a source build 2.56.4-szel | NE telepítsd a `ros-humble-realsense2-camera`-t (DEPENDS-eli a librealsense2-t) |

Plusz **H7 cross-distro fix** (külön session-ben): `net.core.rmem_max` és cyclonedds `SocketReceiveBufferSize` tune a 3.7 MB-os PointCloud2 üzenetekre.

---

## 12. Rollback-stratégia

```bash
# 1. Isaac container stop
docker compose -f docker-compose.isaac-humble.yml down

# 2. Vissza a régi (Jazzy stack-only) konfigra
docker compose up -d  # default docker-compose.yml (Jazzy realsense)

# 3. Git-szintű visszaállás (ha kell)
git checkout main  # vagy az előző "pre-isaac" tag

# 4. Cyclonedds buffer tune visszavonása (a kis-message-eket nem érinti, de purist)
sudo rm /etc/sysctl.d/99-ros2-dds-buffer.conf
sudo sysctl -w net.core.rmem_max=1048576
sudo sysctl -w net.core.wmem_max=212992
```

---

## 13. Long-term migration path (JetPack 7.2 után)

JetPack 7.2 megjelenése (Q2 2026 NVIDIA staff kayccc) **fokozatos átállás Jazzy-natív Isaac 4.x-re**:
1. JetPack 7.2 install Orin-on
2. Isaac apt `release-3.0` → `release-4.x`
3. Humble container fokozatos átállás Jazzy-natív Isaac-ra
4. Heterogén stack megszűnik, single-stack Jazzy

---

## 14. Reproduction checklist (másik roboton)

- [ ] Jetson Orin Nano 8 GB + L4T R36.4.x + JP6.x
- [ ] D435i kamera + FW 5.16+ (5.17.0.10 verified)
- [ ] 25+ GB szabad disk space
- [ ] 4+ GB szabad idle RAM
- [ ] Docker nvidia runtime default
- [ ] udev rules librealsense permission (`99-realsense-libusb.rules`)
- [ ] **sysctl tune** `/etc/sysctl.d/99-ros2-dds-buffer.conf` (64 MB rmem/wmem)
- [ ] `Dockerfile.isaac-humble` + `docker-compose.isaac-humble.yml` + `launch/isaac_realsense.launch.py` + `realsense_params.isaac.yaml` + `cyclonedds.xml` a fenti tartalommal
- [ ] `docker compose build` (~25-30 perc első alkalommal)
- [ ] `docker compose up -d`
- [ ] Validation: 30 Hz pointcloud Humble-side + Jazzy-side, RAM < 500 MB, RestartCount 0

---

## Hivatkozások

- NVIDIA Isaac ROS Documentation: <https://nvidia-isaac-ros.github.io/>
- Isaac ROS realsense fork: <https://github.com/NVIDIA-ISAAC-ROS/realsense-ros/tree/release/4.51.1-isaac>
- librealsense releases: <https://github.com/IntelRealSense/librealsense/releases>
- CV-CUDA releases: <https://github.com/CVCUDA/CV-CUDA/releases>
- CycloneDDS config reference: <https://cyclonedds.io/docs/cyclonedds/latest/config/options.html>
