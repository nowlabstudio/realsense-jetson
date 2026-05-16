"""Isaac NITROS RealSense launch — backportált az NVIDIA stock mintából.

Komponensek (mind egy ComposableNodeContainer-ben, zero-copy NITROS):
  1. realsense2_camera_node (Isaac fork 4.51.1-isaac, libRS 2.56.4)
  2. ConvertMetricNode (Z16 mm uint16 → float32 m, NITROS-tagged)
  3. PointCloudXyzNode (GPU NITROS pointcloud → /camera/depth/points)

Hardware: D435i, FW 5.17.0.10, USB 3.2 SuperSpeed.

Key delta a korábbi (broken) launch-hoz képest:
  - Node name 'realsense2_camera' (NEM 'camera') — NITROS topic-discovery a node-nevet
    használja, a 'camera' nevvel nem matchel a stock pipeline elvárása.
  - Parameters: YAML config file (`realsense_mono_depth.yaml`), NEM inline dict —
    az NVIDIA stock minta ezt használja, kontrollált paraméter-set.
  - Remappings: color/image_raw → image_rect, color/camera_info → camera_info_rect —
    a downstream image_proc/depth_image_proc-knak ezt a sémát várja.
  - 640x480x15 profile (a YAML-ben) — 30 fps-en a USB control_transfer EAGAIN
    rosszabb (D435i kontroller throughput-szűk).
  - emitter OFF (a YAML-ben) — passive stereo, kisebb USB-bandwidth.

Root cause fix (G1: 2.55.1 → 2.56.4): a librealsense 2.55.1 RSUSB build
JP6 r36.4-on instabil (control_transfer EAGAIN, 0 frame); a 2.56.4 stabil (a
Jazzy stack baseline-ja ugyanezen kamerán 30 Hz depth-et publikált).
"""

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import LogInfo
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode


def generate_launch_description():
    # Talicska-specifikus override (bind-mountolt YAML, 30 fps + IMU off).
    # Image-rebuild nélkül módosítható: realsense_params.isaac.yaml a project-
    # gyökérben. Fallback a stock NVIDIA mintára (15 fps), ha nincs mount.
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

    # Z16 mm uint16 → float32 m, NITROS-tagged.
    convert_metric_node = ComposableNode(
        package='isaac_ros_depth_image_proc',
        plugin='nvidia::isaac_ros::depth_image_proc::ConvertMetricNode',
        name='convert_metric',
        remappings=[
            ('image_raw', '/aligned_depth_to_color/image_raw'),
            ('image', '/depth'),
        ],
    )

    # GPU NITROS pointcloud. A camera_info az aligned (color frame) info,
    # mert a depth color frame-be aligned (align_depth.enable: true).
    # Output remap a downstream Nav2 VoxelLayer-nek a hagyományos topic-séma.
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
        LogInfo(msg=(
            'Starting Isaac NITROS RealSense pipeline '
            '(D435i, FW 5.17.0.10, libRS 2.56.4, Isaac fork 4.51.1-isaac)'
        )),
        container,
    ])
