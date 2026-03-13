// =============================================================================
// distance_center — RealSense D435i · ROS2 Jazzy
// =============================================================================
// Méri a kép középpontjától különböző területek távolságát az aligned depth
// képből. Az ötlet a realsense_samples_ros objektum-lokalizációs sample-jéből
// ered, itt egyszerűsítve: rögzített ROI-kra (középpont + 9 zóna) mér.
//
// Publikál: /realsense/distances (std_msgs/String) — JSON-szerű összefoglaló
//
// Feliratkoz: /camera/camera/aligned_depth_to_color/image_raw
//
// Futtatás:
//   ros2 run realsense_d435i_examples distance_center
// =============================================================================

#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/image.hpp>
#include <std_msgs/msg/string.hpp>
#include <cv_bridge/cv_bridge.hpp>
#include <opencv2/core.hpp>
#include <sstream>
#include <iomanip>

class DistanceCenter : public rclcpp::Node
{
public:
    DistanceCenter()
    : Node("distance_center"), frame_count_(0)
    {
        // Aligned depth: a depth már a color frame-hez igazítva
        depth_sub_ = create_subscription<sensor_msgs::msg::Image>(
            "/camera/camera/aligned_depth_to_color/image_raw", 10,
            std::bind(&DistanceCenter::callback, this, std::placeholders::_1));

        dist_pub_ = create_publisher<std_msgs::msg::String>(
            "/realsense/distances", 10);

        RCLCPP_INFO(get_logger(),
            "distance_center indítva. Várakozás aligned_depth_to_color topicra...");
        RCLCPP_INFO(get_logger(),
            "Publish: /realsense/distances");
    }

private:
    rclcpp::Subscription<sensor_msgs::msg::Image>::SharedPtr depth_sub_;
    rclcpp::Publisher<std_msgs::msg::String>::SharedPtr dist_pub_;
    int frame_count_;

    // Egy ROI átlagos távolsága (érvényes pixelek alapján)
    float roi_mean_dist(const cv::Mat & depth_m, int cx, int cy, int r) const
    {
        int x0 = std::max(0, cx - r), x1 = std::min(depth_m.cols - 1, cx + r);
        int y0 = std::max(0, cy - r), y1 = std::min(depth_m.rows - 1, cy + r);
        cv::Rect roi(x0, y0, x1 - x0 + 1, y1 - y0 + 1);
        cv::Mat patch = depth_m(roi);
        cv::Mat valid_mask = (patch > 0.05f) & (patch < 10.0f);
        if (cv::countNonZero(valid_mask) == 0) return -1.0f;
        return static_cast<float>(cv::mean(patch, valid_mask)[0]);
    }

    void callback(const sensor_msgs::msg::Image::ConstSharedPtr & msg)
    {
        ++frame_count_;
        if (frame_count_ % 10 != 0) return; // 10 frame-enként mér

        cv::Mat depth_m;
        try {
            auto cv_img = cv_bridge::toCvShare(msg, "16UC1");
            cv_img->image.convertTo(depth_m, CV_32F, 0.001f); // mm → m
        } catch (const cv_bridge::Exception & e) {
            RCLCPP_WARN(get_logger(), "cv_bridge hiba: %s", e.what());
            return;
        }

        int W = depth_m.cols, H = depth_m.rows;
        int cx = W / 2, cy = H / 2;
        int r = std::min(W, H) / 12; // ROI sugár

        // 9 zóna: 3x3 rács a kép középső harmadában
        // Elnevezések: TL, TC, TR / ML, MC, MR / BL, BC, BR
        const std::array<std::pair<int,int>, 9> zones = {{
            {cx - W/4, cy - H/4}, {cx, cy - H/4}, {cx + W/4, cy - H/4},  // top
            {cx - W/4, cy      }, {cx, cy      }, {cx + W/4, cy      },  // mid
            {cx - W/4, cy + H/4}, {cx, cy + H/4}, {cx + W/4, cy + H/4}   // bot
        }};
        const std::array<const char*, 9> names = {
            "TL","TC","TR","ML","MC","MR","BL","BC","BR"
        };

        std::ostringstream oss;
        oss << std::fixed << std::setprecision(3);
        oss << "{\"frame\":" << frame_count_ << ",\"distances\":{";
        for (std::size_t i = 0; i < zones.size(); ++i) {
            float d = roi_mean_dist(depth_m, zones[i].first, zones[i].second, r);
            oss << "\"" << names[i] << "\":";
            if (d > 0) oss << d; else oss << "null";
            if (i < zones.size() - 1) oss << ",";
        }
        oss << "}}";

        // Log + publish
        RCLCPP_INFO(get_logger(), "%s", oss.str().c_str());
        std_msgs::msg::String out;
        out.data = oss.str();
        dist_pub_->publish(out);
    }
};

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);
    rclcpp::spin(std::make_shared<DistanceCenter>());
    rclcpp::shutdown();
    return 0;
}
