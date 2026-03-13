// =============================================================================
// imu_subscriber — RealSense D435i · ROS2 Jazzy
// =============================================================================
// Feliratkozik a /camera/camera/imu topicra (unite_imu_method:=2 módban
// a realsense2_camera node egyesített accel+gyro adatot publikál).
//
// Kiírja:
//   - Lineáris gyorsulás (m/s²) — accel
//   - Szögsebességek (rad/s)    — gyro
//   - Becsült dőlésszög (pitch, roll) az accel alapján
//
// Futtatás:
//   ros2 run realsense_d435i_examples imu_subscriber
// =============================================================================

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <cmath>

class ImuSubscriber : public rclcpp::Node
{
public:
    ImuSubscriber()
    : Node("imu_subscriber"), msg_count_(0)
    {
        sub_ = create_subscription<sensor_msgs::msg::Imu>(
            "/camera/camera/imu", 100,
            std::bind(&ImuSubscriber::callback, this, std::placeholders::_1));

        RCLCPP_INFO(get_logger(),
            "imu_subscriber indítva. Várakozás /camera/camera/imu topicra...");
    }

private:
    rclcpp::Subscription<sensor_msgs::msg::Imu>::SharedPtr sub_;
    int msg_count_;

    void callback(const sensor_msgs::msg::Imu::SharedPtr msg)
    {
        ++msg_count_;

        // Minden 50. üzenetnél (kb. ~3 mp 63Hz accel-nél) részletes log
        if (msg_count_ % 50 != 0) return;

        const auto & a = msg->linear_acceleration;
        const auto & g = msg->angular_velocity;

        // Gravitáció alapú dőlésszög becslés (statikus esetben pontos)
        double roll  = std::atan2(a.y, a.z) * 180.0 / M_PI;
        double pitch = std::atan2(-a.x, std::sqrt(a.y * a.y + a.z * a.z)) * 180.0 / M_PI;

        RCLCPP_INFO(get_logger(),
            "[IMU #%5d] Accel: x=%+6.3f y=%+6.3f z=%+6.3f m/s² | "
            "Gyro: x=%+6.3f y=%+6.3f z=%+6.3f rad/s | "
            "Dőlés: pitch=%+6.1f° roll=%+6.1f°",
            msg_count_,
            a.x, a.y, a.z,
            g.x, g.y, g.z,
            pitch, roll);
    }
};

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);
    rclcpp::spin(std::make_shared<ImuSubscriber>());
    rclcpp::shutdown();
    return 0;
}
