# RealSense D435i — ROS2 Examples

ROS2 Jazzy C++ példák a kamera adatok fogyasztásához.

---

## Szükséges stream konfiguráció

A production stack depth-only módban fut. Egyes példák color/aligned/pointcloud
streameket igényelnek — ezeket a `docker-compose.yml` command részében kell engedélyezni.

| Example | Szükséges streamek | Production configgal fut? |
|---|---|---|
| `imu_subscriber` | imu | ✓ |
| `rgbd_subscriber` | color + depth | ✗ — `enable_color:=true` kell |
| `pointcloud_subscriber` | pointcloud | ✗ — `pointcloud.enable:=true` kell |
| `distance_center` | aligned_depth_to_color | ✗ — `enable_color:=true` + `align_depth.enable:=true` kell |
| `aligned_rgbd` | color + aligned_depth | ✗ — `enable_color:=true` + `align_depth.enable:=true` kell |

---

## Fordítás és futtatás

A `ros2_realsense` konténerben (ahol a ROS2 workspace elérhető):

```bash
# Fájlok másolása konténerbe
docker cp examples/ ros2_realsense:/opt/examples

# Fordítás
docker exec -it ros2_realsense bash -c "
  cd /opt/examples &&
  colcon build --merge-install &&
  source install/setup.bash"

# Futtatás (pl. IMU)
docker exec -it ros2_realsense bash -c "
  source /opt/examples/install/setup.bash &&
  ros2 run realsense_d435i_examples imu_subscriber"
```

---

## Példák leírása

### `imu_subscriber`
Accel + gyro adatok, becsült dőlésszög (pitch, roll) kiírása.
Topic: `/camera/camera/imu`

### `rgbd_subscriber`
Color + depth frame szinkronizált fogadása, átlag mélység számítás.
Topics: `/camera/camera/color/image_raw` + `/camera/camera/depth/image_rect_raw`

### `pointcloud_subscriber`
PointCloud2 fogadása, érvényes pontok száma + 3D bounding box.
Topic: `/camera/camera/depth/color/points`

### `distance_center`
Aligned depth alapján 9 zónás távolságmérés (3×3 rács), JSON kimenet.
Topic: `/camera/camera/aligned_depth_to_color/image_raw`

### `aligned_rgbd`
Color + aligned depth szinkronizáció ellenőrzése, timestamp eltérés mérés.
Topics: `/camera/camera/color/image_raw` + `/camera/camera/aligned_depth_to_color/image_raw`

---

## Megjegyzés

Ezek a példák **nem teszteltek** — referencia implementációként szolgálnak.
A production konfigurációban csak az `imu_subscriber` fut azonnal.
