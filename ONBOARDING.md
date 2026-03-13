# RealSense D435i · Jetson Orin Nano · Gyors útmutató

---

## Mi ez?

**Intel RealSense D435i** mélységi kamera teljes Docker infrastruktúrája egy
**Jetson Orin Nano** (JetPack 6.2) gépen.

Elérhető: RGB + Depth (RGBD) + IMU (accel/gyro) + PointCloud + ROS2

**librealsense verzió:** 2.56.5 (forrásból fordítva, RSUSB backend)

---

## Egyszer csináld meg (telepítés)

```bash
cd ~/realsense-docker
bash install.sh
```

Ez automatikusan:
- Telepíti a Dockert
- Beállítja a GPU (CUDA) hozzáférést konténerekből
- Telepíti az udev rules-t (USB jogosultság)
- Lefordítja a librealsense 2.56.5 SDK-t forrásból (~25-40 perc)
- Lefordítja a ROS2 Jazzy + realsense2_camera image-et
- Mindent logol → `logs/install_latest.log`

---

## Napi használat

```bash
# Indítás
bash scripts/start.sh

# Leállítás
bash scripts/stop.sh

# Mi fut?
bash scripts/status.sh
```

---

## 2 konténer, 2 szerepkör

```
realsense_sdk      → C++ fejlesztés, raw SDK, rs-* eszközök
ros2_realsense     → ROS2 topicok (SLAM, Nav2, rviz2)
```

---

## Gyors tesztek

```bash
# Minden OK?
bash scripts/test_realsense.sh

# Csak gyorsan
bash scripts/test_realsense.sh --quick

# Kamera látszik-e?
lsusb | grep Intel

# Közvetlen SDK teszt
docker exec realsense_sdk rs-enumerate-devices --compact
```

---

## Kamera elérése C++-ból

A `realsense_sdk` konténerben teljes C++ toolchain (gcc, cmake, pkg-config) és
a librealsense headers (`/usr/local/include/librealsense2/`) elérhetők.

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
cfg.enable_stream(RS2_STREAM_COLOR, 640, 480, RS2_FORMAT_YUYV, 6);
pipe.start(cfg);

auto frames = pipe.wait_for_frames();
auto depth  = frames.get_depth_frame();
float dist  = depth.get_distance(320, 240);
// dist = távolság méterben a kép közepén
pipe.stop();
```

**IMU streamek:**
```cpp
cfg.enable_stream(RS2_STREAM_ACCEL, RS2_FORMAT_MOTION_XYZ32F, 63);   // 63 vagy 250 Hz
cfg.enable_stream(RS2_STREAM_GYRO,  RS2_FORMAT_MOTION_XYZ32F, 200);  // 200 vagy 400 Hz
```

---

## ROS2 topicok (gyors lista)

```bash
docker exec ros2_realsense bash -c \
  "source /opt/ros/jazzy/setup.bash && ros2 topic list"
```

| Topic | Tartalom |
|-------|---------|
| `/camera/color/image_raw` | RGB kép |
| `/camera/depth/image_rect_raw` | Mélységi kép |
| `/camera/depth/color/points` | 3D pontfelhő |
| `/camera/imu` | IMU (accel + gyro) |

---

## Saját C++ alkalmazás futtatása

```bash
# Fájl másolása konténerbe
docker cp myapp.cpp realsense_sdk:/app/

# Fordítás és futtatás a konténerben
docker exec -it realsense_sdk bash -c "
  g++ -O2 /app/myapp.cpp -o /app/myapp \$(pkg-config --cflags --libs realsense2) &&
  /app/myapp"
```

---

## USB sávszélesség korlát

Ha a kamera **USB 2.0 (480M)** sebességgel csatlakozik (pl. telefon töltőkábellel):
- Depth: 640×480 @30fps ✓
- Color: max 640×480 @6fps
- IMU: teljes sebességgel ✓

**USB 3.0 adatkábellel** (5Gbps): Color 1280×720 @30fps is elérhető.

---

## Ha valami nem megy

```bash
# Log ellenőrzés
tail -50 logs/install_latest.log

# Konténer újraindítás
docker compose restart realsense-sdk

# USB jogosultság reset
sudo udevadm trigger

# Teljes reset
docker compose down
docker compose up -d
```

---

## Rendszer lábnyom

| Elem | Méret |
|------|-------|
| realsense-sdk:2.56.5 image | ~500 MB |
| ros2-realsense image | ~4-6 GB |
| Natív telepítés | <500 MB |

---

## Fájlok

```
~/realsense-docker/
├── install.sh              ← Telepítő (idempotent)
├── docker-compose.yml      ← Stack
├── README.md               ← Részletes dok.
├── ONBOARDING.md           ← Ez a fájl
├── logs/                   ← Naplók
├── scripts/                ← Kényelmi szkriptek
├── realsense-sdk/          ← SDK Dockerfile (2.56.5, forrásból)
└── ros2-realsense/         ← ROS2 Jazzy Dockerfile
```
