// =============================================================================
// pointcloud_subscriber — RealSense D435i · ROS2 Jazzy
// =============================================================================
// Feliratkozik a /camera/camera/depth/color/points (PointCloud2) topicra.
//
// Minden fogadott felhőnél kiszámítja:
//   - Összes pont száma
//   - Érvényes pontok száma (Z > 0)
//   - Legközelebbi / legtávolabbi pont Z koordinátája
//   - 3D bounding box (min/max XYZ)
//
// Futtatás:
//   ros2 run realsense_d435i_examples pointcloud_subscriber
// =============================================================================

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>
#include <sensor_msgs/point_cloud2_iterator.hpp>
#include <limits>

class PointCloudSubscriber : public rclcpp::Node
{
public:
    PointCloudSubscriber()
    : Node("pointcloud_subscriber"), cloud_count_(0)
    {
        sub_ = create_subscription<sensor_msgs::msg::PointCloud2>(
            "/camera/camera/depth/color/points", 5,
            std::bind(&PointCloudSubscriber::callback, this, std::placeholders::_1));

        RCLCPP_INFO(get_logger(),
            "pointcloud_subscriber indítva. Várakozás /camera/camera/depth/color/points topicra...");
    }

private:
    rclcpp::Subscription<sensor_msgs::msg::PointCloud2>::SharedPtr sub_;
    int cloud_count_;

    void callback(const sensor_msgs::msg::PointCloud2::SharedPtr msg)
    {
        ++cloud_count_;

        float min_x = std::numeric_limits<float>::max();
        float max_x = std::numeric_limits<float>::lowest();
        float min_y = min_x, max_y = max_x;
        float min_z = min_x, max_z = max_x;
        int valid = 0;

        sensor_msgs::PointCloud2ConstIterator<float> it_x(*msg, "x");
        sensor_msgs::PointCloud2ConstIterator<float> it_y(*msg, "y");
        sensor_msgs::PointCloud2ConstIterator<float> it_z(*msg, "z");

        for (; it_x != it_x.end(); ++it_x, ++it_y, ++it_z) {
            float z = *it_z;
            if (!std::isfinite(z) || z <= 0.0f) continue;

            float x = *it_x, y = *it_y;
            ++valid;
            min_x = std::min(min_x, x); max_x = std::max(max_x, x);
            min_y = std::min(min_y, y); max_y = std::max(max_y, y);
            min_z = std::min(min_z, z); max_z = std::max(max_z, z);
        }

        int total = static_cast<int>(msg->width * msg->height);

        RCLCPP_INFO(get_logger(),
            "[Cloud #%4d] Pontok: %d/%d érvényes | "
            "Z: %.3f–%.3f m | "
            "BBox: X[%.2f..%.2f] Y[%.2f..%.2f] m",
            cloud_count_,
            valid, total,
            (valid > 0 ? min_z : 0.0f), (valid > 0 ? max_z : 0.0f),
            (valid > 0 ? min_x : 0.0f), (valid > 0 ? max_x : 0.0f),
            (valid > 0 ? min_y : 0.0f), (valid > 0 ? max_y : 0.0f));
    }
};

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);
    rclcpp::spin(std::make_shared<PointCloudSubscriber>());
    rclcpp::shutdown();
    return 0;
}
