# RealSense D435i · Jetson Orin Nano · Gyors útmutató

---

## Mi ez?

**Intel RealSense D435i** mélységi kamera Docker infrastruktúrája
**Jetson Orin Nano** (JetPack 6.2) gépen, SLAM/navigáció adatforrásként.

Kimenet: Depth + Stereo IR + IMU → ROS2 topicok → SLAM / sensor fusion / obstacle avoidance

**librealsense:** 2.56.5 (SDK), 2.56.4 (ROS2) · **Backend:** RSUSB (kernel modul nélkül)

---

## Telepítés (egyszer)

```bash
cd ~/realsense-docker
bash install.sh
```

Opciók:
```
--verbose    Log ablak megnyitása külön terminálban
--no-ros2    ROS2 image build kihagyása (csak SDK)
--help       Részletes súgó
```

Telepítési idő: ~80-110 perc (ARM64, forrásból fordít mindent)

---

## Napi használat

```bash
bash scripts/start.sh     # stack indítás
bash scripts/stop.sh      # leállítás
bash scripts/status.sh    # státusz + GPU + ROS2 topicok
```

---

## Konténerek

```
realsense_sdk      → C++ fejlesztés, raw SDK, rs-* eszközök
ros2_realsense     → ROS2 Jazzy, kamera adatokat publikálja
```

---

## ROS2 topicok

```bash
docker exec ros2_realsense bash -c \
  "source /opt/ros2-camera-install/setup.bash && ros2 topic list"
```

| Topic | Tartalom | Ráta |
|-------|---------|------|
| `/camera/camera/depth/image_rect_raw` | Mélységi kép (Z16) | 30fps |
| `/camera/camera/infra1/image_rect_raw` | Bal IR (vizuális odometria) | 30fps |
| `/camera/camera/infra2/image_rect_raw` | Jobb IR (vizuális odometria) | 30fps |
| `/camera/camera/imu` | Fúzionált IMU (accel+gyro) | ~200Hz |
| `/camera/camera/gyro/sample` | Nyers giroszkóp | 400Hz |
| `/camera/camera/accel/sample` | Nyers gyorsulásmérő | 250Hz |

> Color, RGBD, PointCloud **ki van kapcsolva** — a fogyasztó SLAM stack végzi a feldolgozást.

---

## Tesztek

```bash
bash scripts/test_realsense.sh           # teljes (10 teszt)
bash scripts/test_realsense.sh --quick   # gyors (6 teszt)

lsusb | grep Intel                       # kamera látszik?
docker exec realsense_sdk rs-enumerate-devices --compact
```

---

## Fejlesztői eszközök (dev)

```bash
bash scripts/viewer.sh       # realsense-viewer GUI (leállítja a ros2-t, majd visszaindítja)
bash scripts/viewer-debug.sh # viewer + teljes hibanapló a terminálban
```

A viewer külön image (`realsense-viewer:2.56.5`) — nincs hatással a production stackre.

---

## C++ fejlesztés (realsense_sdk konténer)

```bash
docker exec -it realsense_sdk bash
```

```cpp
// CMakeLists.txt
find_package(realsense2 REQUIRED)
target_link_libraries(myapp realsense2::realsense2)
```

```cpp
#include <librealsense2/rs.hpp>

rs2::pipeline pipe;
rs2::config cfg;
cfg.enable_stream(RS2_STREAM_DEPTH, 640, 480, RS2_FORMAT_Z16, 30);
cfg.enable_stream(RS2_STREAM_ACCEL, RS2_FORMAT_MOTION_XYZ32F, 250);
cfg.enable_stream(RS2_STREAM_GYRO,  RS2_FORMAT_MOTION_XYZ32F, 400);
pipe.start(cfg);

auto frames = pipe.wait_for_frames();
auto depth  = frames.get_depth_frame();
float dist  = depth.get_distance(320, 240); // méter
pipe.stop();
```

```bash
# Saját alkalmazás fordítása
docker cp myapp.cpp realsense_sdk:/app/
docker exec -it realsense_sdk bash -c \
  "g++ -O3 /app/myapp.cpp -o /app/myapp \$(pkg-config --cflags --libs realsense2) && /app/myapp"
```

---

## USB sávszélesség

A J401 board összes USB portja egy hubon osztozik (10 Gbps upstream).

| Konfiguráció | Igény | Fér el? |
|---|---|---|
| 1× depth + IR + IMU | ~420 Mbps | ✓ |
| 4× depth + IR + IMU | ~1.7 Gbps | ✓ |
| 1× depth + color + IR + IMU | ~1 Gbps | ✓ |

Aktuális kábel: **USB 3.2 Gen 2 (10 Gbps)** — ellenőrzés:
```bash
docker exec realsense_sdk rs-enumerate-devices --compact | grep "Usb Type"
# → Usb Type Descriptor: 3.2
```

---

## Ha valami nem megy

```bash
tail -50 logs/install_latest.log      # telepítési log
docker compose restart ros2-realsense # konténer újraindítás
sudo udevadm control --reload-rules && sudo udevadm trigger  # USB jogosultság
docker compose down && docker compose up -d  # teljes reset
```

---

## Fájlstruktúra

```
~/realsense-docker/
├── install.sh                  ← Telepítő (idempotent, --help, --verbose, --no-ros2)
├── docker-compose.yml          ← Production stack
├── docker-compose.dev.yml      ← Dev eszközök (viewer)
├── README.md                   ← Részletes dokumentáció
├── ONBOARDING.md               ← Ez a fájl
├── logs/                       ← Telepítési és tesztelési naplók
├── scripts/
│   ├── start.sh / stop.sh / status.sh
│   ├── test_realsense.sh
│   ├── viewer.sh               ← GUI viewer (dev)
│   └── viewer-debug.sh         ← Viewer + hibanapló
├── realsense-sdk/              ← librealsense 2.56.5 Dockerfile
├── ros2-realsense/             ← ROS2 Jazzy + realsense2_camera Dockerfile
└── realsense-viewer/           ← Viewer Dockerfile (dev only)
```

---

## Rendszer lábnyom

| Image | Méret |
|-------|-------|
| realsense-sdk:2.56.5 | ~500 MB |
| ros2-realsense:r36.4.0 | ~3-4 GB |
| realsense-viewer:2.56.5 | ~1.5 GB |
| Natív telepítés | <500 MB |
