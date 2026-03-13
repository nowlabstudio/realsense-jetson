// =============================================================================
// aligned_rgbd — RealSense D435i · ROS2 Jazzy
// =============================================================================
// Time-synchronized Color + Aligned Depth subscriber.
// Ellenőrzi hogy a color és aligned depth frame-ek szinkronban érkeznek,
// és minden frame-párra kiszámítja:
//   - Felbontások egyezése (elvárás: azonos WxH)
//   - Mélység lefedettség (valid depth pixelek %-a)
//   - Középső 10% ROI átlag mélysége
//
// Ez az aligned_depth_to_color topicot használja — a depth már a color
// koordináta-rendszerébe transzformált, így pixel-pontos RGBD lehetséges.
//
// Futtatás:
//   ros2 run realsense_d435i_examples aligned_rgbd
// =============================================================================

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <message_filters/subscriber.h>
#include <message_filters/sync_policies/approximate_time.h>
#include <message_filters/synchronizer.h>
#include <cv_bridge/cv_bridge.hpp>
#include <opencv2/core.hpp>

class AlignedRgbd : public rclcpp::Node
{
public:
    AlignedRgbd()
    : Node("aligned_rgbd"), frame_count_(0)
    {
        color_sub_.subscribe(this, "/camera/camera/color/image_raw");
        depth_sub_.subscribe(this, "/camera/camera/aligned_depth_to_color/image_raw");

        sync_ = std::make_shared<Sync>(SyncPolicy(10), color_sub_, depth_sub_);
        sync_->registerCallback(
            std::bind(&AlignedRgbd::callback, this,
                      std::placeholders::_1, std::placeholders::_2));

        RCLCPP_INFO(get_logger(), "aligned_rgbd indítva.");
        RCLCPP_INFO(get_logger(),
            "Topics: color/image_raw + aligned_depth_to_color/image_raw");
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
        if (frame_count_ % 30 != 0) return;

        // Felbontás ellenőrzés: aligned depth == color méret
        bool size_ok = (color_msg->width  == depth_msg->width &&
                        color_msg->height == depth_msg->height);

        if (!size_ok) {
            RCLCPP_WARN(get_logger(),
                "[Frame %4d] Méret eltérés! Color: %ux%u, Depth: %ux%u",
                frame_count_,
                color_msg->width, color_msg->height,
                depth_msg->width, depth_msg->height);
            return;
        }

        // Depth feldolgozás
        cv::Mat depth_m;
        try {
            auto cv_depth = cv_bridge::toCvShare(depth_msg, "16UC1");
            cv_depth->image.convertTo(depth_m, CV_32F, 0.001f);
        } catch (const cv_bridge::Exception & e) {
            RCLCPP_WARN(get_logger(), "cv_bridge hiba: %s", e.what());
            return;
        }

        int W = depth_m.cols, H = depth_m.rows;

        // Teljes kép lefedettség
        cv::Mat valid_mask = (depth_m > 0.1f) & (depth_m < 10.0f);
        int valid_px = cv::countNonZero(valid_mask);
        float coverage = 100.0f * valid_px / (W * H);

        // Középső 10% ROI átlag mélység
        int mx = W / 2, my = H / 2;
        int rw = W / 10, rh = H / 10;
        cv::Rect center_roi(mx - rw, my - rh, 2 * rw, 2 * rh);
        cv::Mat center_patch = depth_m(center_roi);
        cv::Mat center_mask  = (center_patch > 0.1f) & (center_patch < 10.0f);
        float center_dist = -1.0f;
        if (cv::countNonZero(center_mask) > 0) {
            center_dist = static_cast<float>(cv::mean(center_patch, center_mask)[0]);
        }

        // Timestamp eltérés ellenőrzés
        rclcpp::Time t_color(color_msg->header.stamp);
        rclcpp::Time t_depth(depth_msg->header.stamp);
        double dt_ms = std::abs((t_color - t_depth).seconds()) * 1000.0;

        RCLCPP_INFO(get_logger(),
            "[Frame %4d] %ux%u | Coverage: %5.1f%% | "
            "Közép: %s | dt=%.1fms | Color: %s",
            frame_count_,
            W, H,
            coverage,
            (center_dist > 0 ? (std::to_string(center_dist).substr(0,5) + "m").c_str()
                             : "N/A"),
            dt_ms,
            color_msg->encoding.c_str());
    }
};

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);
    rclcpp::spin(std::make_shared<AlignedRgbd>());
    rclcpp::shutdown();
    return 0;
}
