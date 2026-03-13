// =============================================================================
// rgbd_subscriber — RealSense D435i · ROS2 Jazzy
// =============================================================================
// Feliratkozik a realsense2_camera által publikált Color és Depth streamekre.
// Kiírja a frame felbontást, encoding-ot és az átlagos mélységet minden 30.
// frame-nél.
//
// Futtatás (ros2_realsense konténerben):
//   source /opt/ros/jazzy/setup.bash
//   ros2 run realsense_d435i_examples rgbd_subscriber
//
// Fontos: a realsense2_camera node-nak futnia kell előtte.
// =============================================================================

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <message_filters/subscriber.h>
#include <message_filters/time_synchronizer.h>
#include <message_filters/sync_policies/approximate_time.h>
#include <cv_bridge/cv_bridge.hpp>
#include <opencv2/core.hpp>

using namespace std::chrono_literals;

class RgbdSubscriber : public rclcpp::Node
{
public:
    RgbdSubscriber()
    : Node("rgbd_subscriber"), frame_count_(0)
    {
        // ApproximateTime: color és depth timestamp-je nem mindig pontos match
        color_sub_.subscribe(this, "/camera/camera/color/image_raw");
        depth_sub_.subscribe(this, "/camera/camera/depth/image_rect_raw");

        sync_ = std::make_shared<Sync>(SyncPolicy(10), color_sub_, depth_sub_);
        sync_->registerCallback(
            std::bind(&RgbdSubscriber::callback, this,
                      std::placeholders::_1, std::placeholders::_2));

        RCLCPP_INFO(get_logger(),
            "rgbd_subscriber indítva. Várakozás /camera/camera/color + depth topicokra...");
    }

private:
    using SyncPolicy = message_filters::sync_policies::ApproximateTime<
        sensor_msgs::msg::Image,
        sensor_msgs::msg::Image>;
    using Sync = message_filters::Synchronizer<SyncPolicy>;

    message_filters::Subscriber<sensor_msgs::msg::Image> color_sub_;
    message_filters::Subscriber<sensor_msgs::msg::Image> depth_sub_;
    std::shared_ptr<Sync> sync_;
    int frame_count_;

    void callback(
        const sensor_msgs::msg::Image::ConstSharedPtr & color_msg,
        const sensor_msgs::msg::Image::ConstSharedPtr & depth_msg)
    {
        ++frame_count_;

        // Minden 30. frame-nél részletes log
        if (frame_count_ % 30 != 0) return;

        // Color kép info
        RCLCPP_INFO(get_logger(),
            "[Frame %4d] Color: %ux%u enc=%s",
            frame_count_,
            color_msg->width, color_msg->height,
            color_msg->encoding.c_str());

        // Depth kép: átlagos távolság kiszámítása (0 értékeket kihagyva)
        try {
            auto cv_depth = cv_bridge::toCvShare(depth_msg, "16UC1");
            cv::Mat depth_f;
            cv_depth->image.convertTo(depth_f, CV_32F, 0.001f); // mm → m

            // Csak érvényes pixelek (0 = nincs mérés)
            cv::Mat valid_mask = (cv_depth->image > 0);
            double mean_dist = cv::mean(depth_f, valid_mask)[0];
            int valid_px = cv::countNonZero(valid_mask);

            RCLCPP_INFO(get_logger(),
                "[Frame %4d] Depth: %ux%u | avg=%.3fm | valid=%d/%u px",
                frame_count_,
                depth_msg->width, depth_msg->height,
                mean_dist,
                valid_px,
                depth_msg->width * depth_msg->height);
        } catch (const cv_bridge::Exception & e) {
            RCLCPP_WARN(get_logger(), "cv_bridge hiba: %s", e.what());
        }
    }
};

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);
    rclcpp::spin(std::make_shared<RgbdSubscriber>());
    rclcpp::shutdown();
    return 0;
}
