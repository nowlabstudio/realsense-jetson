# Intel RealSense D435i — Jetson Orin Nano Docker Setup

**Platform:** Seeed reComputer Super J401 · Jetson Orin Nano
**L4T:** R36.4.3 · **JetPack:** 6.2 · **CUDA:** 12.6
**Kamera:** Intel RealSense Depth Camera D435i (RGBD + IMU)

---

## Gyors indítás

```bash
# 1. Telepítés (egyszer, ~35-50 perc)
bash install.sh

# 2. SDK konténer ellenőrzés
docker exec realsense_sdk rs-enumerate-devices --compact

# 3. Validáció
bash scripts/test_realsense.sh
```

---

## Architektúra

```
HOST (natív telepítés — minimális)
├── Docker Engine
├── nvidia-container-toolkit      ← GPU bridge
└── udev rules (99-realsense-*)   ← USB jogosultság

DOCKER KONTÉNEREK
├── realsense-sdk     librealsense2 2.56.5 SDK + C++ toolchain
└── ros2-realsense    ROS2 Jazzy + realsense2_camera node
```

### Miért RSUSB backend?

Az ARM64 apt csomag V4L2 backendel épül, ami kernel modult igényel.
Docker containerben kernel modul nem érhető el → forrásból kell fordítani
`-DFORCE_RSUSB_BACKEND=ON` kapcsolóval.

### Miért kell 3 dolog natívan?

| Komponens | Ok |
|-----------|-----|
| Docker Engine | A konténer daemon maga nem futhat konténerben |
| nvidia-container-toolkit | Kernel-szintű GPU bridge, `/dev/nvidia*` expose |
| udev rules | A Linux kernel USB jogosultságát csak host szinten lehet beállítani |

---

## Fájlstruktúra

```
realsense-docker/
├── install.sh                  # Fő telepítő (idempotent)
├── docker-compose.yml          # Stack definíció
├── logs/
│   ├── install_TIMESTAMP.log   # Telepítési napló
│   ├── install_latest.log      # Legutóbbi log (symlink)
│   └── test_TIMESTAMP.log      # Tesztelési napló
├── scripts/
│   ├── start.sh                # Stack indítás
│   ├── stop.sh                 # Stack leállítás
│   ├── status.sh               # Státusz + GPU + ROS2 topicok
│   └── test_realsense.sh       # Teljes validáció
├── realsense-sdk/
│   └── Dockerfile              # librealsense 2.56.5 forrásból (multi-stage)
└── ros2-realsense/
    ├── Dockerfile              # ROS2 Jazzy + realsense2_camera
    └── entrypoint.sh
```

---

## Telepítési fázisok

| Fázis | Leírás | Idő |
|-------|---------|-----|
| 1 | Docker Engine telepítés | ~5 perc |
| 2 | NVIDIA Container Toolkit | ~5 perc |
| 3 | RealSense udev rules | ~1 perc |
| 4 | librealsense2 2.56.5 image (forrásból build) | ~25-40 perc |
| 5 | ROS2 Jazzy + realsense2_camera image | ~20-30 perc |
| 6-7 | Szkriptek + validáció | ~5 perc |
| **Összesen** | | **~60-85 perc** |

> **Forrásból fordítás oka:** Az ARM64 apt csomagok V4L2 backendel épülnek,
> ami kernel modult igényel — Docker containerben nem működik.
> A `realsense-sdk/Dockerfile` multi-stage build: ~500 MB végső image méret.

---

## Docker Compose szolgáltatások

### `realsense-sdk`
librealsense2 2.56.5 C++ fejlesztői konténer. RSUSB backend (libusb direkt USB).

```bash
# Shell
docker exec -it realsense_sdk bash

# Kamera felsorolás
docker exec realsense_sdk rs-enumerate-devices --compact

# Depth élőkép (terminálban)
docker exec -it realsense_sdk rs-depth

# Firmware verzió ellenőrzés
docker exec realsense_sdk rs-enumerate-devices | grep "Firmware"

# Saját C++ alkalmazás fordítása a konténerben
docker exec -it realsense_sdk bash -c "
  mkdir -p /app/build && cd /app/build &&
  cmake .. -DCMAKE_BUILD_TYPE=Release &&
  make -j\$(nproc)"
```

**Megjegyzés:** A Python bindings (`BUILD_PYTHON_BINDINGS=OFF`) szándékosan
ki van kapcsolva — a konténer C++ fejlesztésre optimalizált.

### `ros2-realsense`
ROS2 Jazzy realsense2_camera node (forrásból fordítva, OpenMP + GLSL). Publikálja:

| Topic | Típus | Leírás |
|-------|-------|---------|
| `/camera/camera/depth/image_rect_raw` | sensor_msgs/Image | Depth 640×480 @30fps |
| `/camera/camera/infra1/image_rect_raw` | sensor_msgs/Image | IR bal @30fps |
| `/camera/camera/infra2/image_rect_raw` | sensor_msgs/Image | IR jobb @30fps |
| `/camera/camera/imu` | sensor_msgs/Imu | Fúzionált IMU ~200Hz |
| `/camera/camera/gyro/sample` | sensor_msgs/Imu | Nyers giroszkóp 400Hz |
| `/camera/camera/accel/sample` | sensor_msgs/Imu | Nyers gyorsulásmérő 250Hz |

> Color, RGBD, PointCloud ki van kapcsolva — a SLAM stack végzi a feldolgozást.

```bash
# Topicok listája (entrypoint automatikusan source-olja a workspace-t)
docker exec ros2_realsense ros2 topic list

# IMU live
docker exec ros2_realsense ros2 topic echo /camera/camera/imu --once

# Depth topic info
docker exec ros2_realsense ros2 topic info /camera/camera/depth/image_rect_raw
```

---

## USB sávszélesség — fontos korlát

A J401 board összes USB portja egy Microchip USB5744 hubon keresztül osztozik egy
USB 3.2 upstream kapcsolaton. Ha a kábel nem SuperSpeed-képes (csak telefon töltő
kábel), a kamera USB 2.0 (480 Mbps) sebességgel üzemel:

| Kábel típusa | Sebesség | Color stream |
|-------------|---------|--------------|
| Telefon töltő USB-C | 480 Mbps (USB 2.0) | max 640×480 @6fps |
| USB-C 5Gbps adatkábel | 5 Gbps (USB 3.2) | 1280×720 @30fps |

**Ajánlott:** USB-C to USB-C kábel, 5Gbps adatátviteli képességgel.

---

## Kényelmi szkriptek

```bash
bash scripts/start.sh     # Stack indítás (docker compose up -d)
bash scripts/stop.sh      # Stack leállítás
bash scripts/status.sh    # Státusz: konténerek + GPU + ROS2 topicok

# Teszt módok:
bash scripts/test_realsense.sh           # Teljes teszt (10 teszt)
bash scripts/test_realsense.sh --quick   # Gyors (6 teszt)
bash scripts/test_realsense.sh --ros2    # + ROS2 topic ellenőrzés
bash scripts/test_realsense.sh --imu     # + Részletes IMU teszt
```

---

## RealSense D435i Szenzor Specifikáció

| Szenzor | Felbontás | FPS | Formátum |
|---------|-----------|-----|---------|
| RGB (Color) | 1920×1080 max | 30 | YUYV/BGR8/RGB8 |
| Depth | 1280×720 max | 30 | Z16 (mm) |
| IR bal/jobb | 1280×800 | 30 | Y8 |
| Accelerometer | — | 63 / 250 Hz | XYZ32F |
| Gyroscope | — | 200 / 400 Hz | XYZ32F |

**IMU szinkronizálás (ROS2):** `unite_imu_method:=2` (lineáris interpoláció)
**Depth hatótáv:** 0.1m – 10m
**FOV (Depth):** 87°×58°×95°

---

## Hibakeresés

### "Permission denied" USB-n
```bash
sudo udevadm trigger --action=add
# Ha nem segít:
sudo udevadm control --reload-rules && sudo udevadm trigger
```

### CUDA nem elérhető konténerből
```bash
sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
sudo systemctl restart docker
```

### IMU stream sikertelen
Az IMU elérhető frekvenciák: Accel **63 Hz** vagy **250 Hz**, Gyro **200 Hz** vagy **400 Hz**.
Ne kérd a 100 Hz-es accel streamet — az nem létezik ezen a hardveren.

### ⚠️ IR emitter és vizuális odometria konfliktus
A D435i IR lézer dot projector (emitter) segíti a depth számítást texturálaltan felületeken,
de **zavarhatja az IR-alapú vizuális odometriát** (ORB-SLAM3, RTAB-Map feature matching).

| Emitter állapot | Depth minőség | Vizuális odometria |
|---|---|---|
| ON (alapértelmezett) | jobb texturálaltan felületeken | feature detection romlik |
| OFF | gyengébb texturálaltan | tiszta IR kép, jobb feature matching |

Kikapcsolás futásidőben (ROS2 paraméter):
```bash
ros2 param set /camera/camera depth_module.emitter_enabled false
```
Vagy a launch command-ban:
```
depth_module.emitter_enabled:=false
```
**Ajánlott:** teszteld mindkét módban a konkrét környezetedben — beltérben (sok textúra)
az emitter általában elhagyható, kültéren vagy sima falaknál szükség lehet rá.

### RealSense "No device connected"
```bash
# USB újracsatlakoztatás szimulálás
sudo udevadm control --reload-rules && sudo udevadm trigger
# Kamera újracsatlakoztatás (fizikai USB kihúzás/bedugás)
lsusb | grep Intel  # ellenőrzés
```

### Image újraépítés
```bash
# SDK image újraépítés (~25-40 perc)
docker compose build realsense-sdk

# ROS2 image újraépítés
docker compose build ros2-realsense
```

### Docker csoport (newgrp)
Docker telepítés után az új session előtt:
```bash
newgrp docker
# vagy kijelentkezés/bejelentkezés
```

---

## Log fájlok

```bash
# Telepítési log
tail -f logs/install_latest.log

# Legutóbbi teszt log
ls -lt logs/test_*.log | head -3

# Konténer logok
docker compose logs -f
docker compose logs ros2-realsense --tail=50
```

---

## Újratelepítés

Az `install.sh` **idempotent** — biztonságosan újrafuttatható:
- Minden lépés ellenőrzi, hogy már elvégzett-e
- Csak a hiányzó/törött komponenseket telepíti újra

```bash
# Teljes újratelepítés
docker compose down
docker rmi realsense-sdk:2.56.5 ros2-realsense:r36.4.0 2>/dev/null || true
bash install.sh

# Csak SDK image újraépítés
docker compose build realsense-sdk
docker compose up -d realsense-sdk
```

---

## Rendszer információ

```bash
# L4T verzió
cat /etc/nv_tegra_release

# JetPack
dpkg -l nvidia-jetpack

# GPU
nvidia-smi

# Docker image-ek
docker images | grep -E "realsense|ros2"

# Futó konténerek
docker ps
```
