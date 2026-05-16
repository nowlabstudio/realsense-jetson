"""Isaac NITROS RealSense launch (Path B — release-3.0 apt component).

Composes 3 NITROS zero-copy nodes inside a single multi-threaded
ComposableNodeContainer:
  1. realsense2_camera (standard ROS Humble v4.57.7-4jammy, NOT Isaac fork)
  2. isaac_ros_image_proc ImageFormatConverterNode (GPU YUYV->RGB)
  3. isaac_ros_depth_image_proc PointCloudXyzNode (GPU pointcloud)

Hardware: D435i, FW 5.17.0.10.
"""

from launch import LaunchDescription
from launch.actions import LogInfo
from launch_ros.actions import ComposableNodeContainer
from launch_ros.descriptions import ComposableNode


def generate_launch_description():
    realsense_node = ComposableNode(
        package='realsense2_camera',
        plugin='realsense2_camera::RealSenseNodeFactory',
        name='camera',
        namespace='',
        parameters=[{
            'enable_color': True,
            'enable_depth': True,
            'enable_infra1': True,
            'enable_infra2': True,
            # IMU re-enabled 2026-05-16; the prior "D435i IMU causes camera
            # freeze" fact was disproven by the 2026-05-16 controlled test.
            'enable_accel': True,
            'enable_gyro': True,
            'enable_sync': False,  # match existing intel-jazzy config
            # unite_imu_method 2 = linear interpolation; unifies accel+gyro
            # into /camera/imu/data
            'unite_imu_method': 2,
            'depth_module.depth_profile': '848x480x30',
            # Smaller RGB profile — NITROS needs lower color for RAM budget.
            'rgb_camera.color_profile': '640x480x30',
            # NITROS PointCloudXyzNode generates the pointcloud instead.
            'pointcloud.enable': False,
            # NITROS uses CUDA; GLSL would conflict.
            'accelerate_gpu_with_glsl': False,
        }],
        extra_arguments=[{'use_intra_process_comms': True}],
    )

    image_format_converter_node = ComposableNode(
        package='isaac_ros_image_proc',
        plugin='nvidia::isaac_ros::image_proc::ImageFormatConverterNode',
        name='image_format_converter',
        parameters=[{'encoding_desired': 'rgb8'}],
        extra_arguments=[{'use_intra_process_comms': True}],
    )

    point_cloud_xyz_node = ComposableNode(
        package='isaac_ros_depth_image_proc',
        plugin='nvidia::isaac_ros::depth_image_proc::PointCloudXyzNode',
        name='point_cloud_xyz',
        remappings=[
            ('image_rect', '/camera/depth/image_rect_raw'),
            ('camera_info', '/camera/depth/camera_info'),
            ('points', '/camera/depth/points'),
        ],
        extra_arguments=[{'use_intra_process_comms': True}],
    )

    container = ComposableNodeContainer(
        name='isaac_realsense_container',
        namespace='',
        package='rclcpp_components',
        executable='component_container_mt',
        composable_node_descriptions=[
            realsense_node,
            image_format_converter_node,
            point_cloud_xyz_node,
        ],
        output='screen',
        emulate_tty=True,
    )

    return LaunchDescription([
        LogInfo(msg=(
            'Starting Isaac NITROS RealSense pipeline '
            '(D435i, FW 5.17.0.10, Path B — release-3.0 apt component)'
        )),
        container,
    ])
