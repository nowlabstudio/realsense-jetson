cmake_minimum_required(VERSION 3.16)
project(realsense_d435i_examples)

# ── C++17 ─────────────────────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_compile_options(-O3 -march=native -Wall -Wextra)

# ── Dependencies ──────────────────────────────────────────────────────────────
find_package(ament_cmake REQUIRED)
find_package(rclcpp REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(std_msgs REQUIRED)
find_package(geometry_msgs REQUIRED)
find_package(cv_bridge REQUIRED)
find_package(image_transport REQUIRED)
find_package(message_filters REQUIRED)
find_package(OpenCV REQUIRED COMPONENTS core imgproc)

set(DEPS
    rclcpp
    sensor_msgs
    std_msgs
    geometry_msgs
    cv_bridge
    image_transport
    message_filters
)

# ── Helper macro ──────────────────────────────────────────────────────────────
macro(add_example name)
  add_executable(${name} src/${name}.cpp)
  ament_target_dependencies(${name} ${DEPS})
  target_link_libraries(${name} ${OpenCV_LIBS})
  install(TARGETS ${name} DESTINATION lib/${PROJECT_NAME})
endmacro()

# ── Examples ──────────────────────────────────────────────────────────────────
add_example(rgbd_subscriber)       # RGB + Depth stream → frame stats
add_example(imu_subscriber)        # IMU accel + gyro
add_example(pointcloud_subscriber) # PointCloud2 → pont szám + bbox
add_example(distance_center)       # Aligned depth → középpont távolság
add_example(aligned_rgbd)          # Time-sync color+depth alignment ellenőrzés

ament_package()
