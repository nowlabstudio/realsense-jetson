#!/bin/bash
# =============================================================================
# RealSense D435i Teljes Validációs Teszt
# =============================================================================
# Futtatás: bash scripts/test_realsense.sh
# Opciók:   --quick    (csak alapvető tesztek)
#           --ros2     (ROS2 topic ellenőrzés is)
#           --imu      (IMU részletes teszt)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/test_$(date +%Y%m%d_%H%M%S).log"

mkdir -p "${LOG_DIR}"

# ── Konfiguráció ──────────────────────────────────────────────────────────────
QUICK=false
TEST_ROS2=false
TEST_IMU_DETAIL=false
for arg in "$@"; do
    case "$arg" in
        --quick)   QUICK=true ;;
        --ros2)    TEST_ROS2=true ;;
        --imu)     TEST_IMU_DETAIL=true ;;
    esac
done

# ── Színek ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

PASS=0; FAIL=0; WARN=0

log() { echo "[$(date '+%H:%M:%S')] $*" >> "${LOG_FILE}"; }
info() { log "INFO $*"; echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { log "PASS $*"; echo -e "${GREEN}[PASS]${NC} $*"; ((PASS++)); }
fail() { log "FAIL $*"; echo -e "${RED}[FAIL]${NC} $*"; ((FAIL++)); }
warn() { log "WARN $*"; echo -e "${YELLOW}[WARN]${NC} $*"; ((WARN++)); }
skip() { log "SKIP $*"; echo -e "${CYAN}[SKIP]${NC} $*"; }

# Dinamikus device lista
USB_DEVICES="--device=/dev/bus/usb:/dev/bus/usb"
VIDEO_DEVICES=""
for vdev in /dev/video*; do
    [[ -e "${vdev}" ]] && VIDEO_DEVICES+=" --device=${vdev}:${vdev}"
done

# SDK container neve (ez fut folyamatosan, ezt használjuk a Python tesztekhez)
SDK_CONTAINER="realsense_sdk"

# RealSense image detektálás (CUDA teszthez)
RS_IMAGE="$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -i "realsense-ai" | head -1 || true)"
[[ -z "${RS_IMAGE}" ]] && RS_IMAGE="$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -i "realsense" | head -1 || true)"

ROS2_IMAGE="$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -i "ros2-realsense" | head -1 || true)"

# SDK container fut-e?
SDK_RUNNING=false
if docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^${SDK_CONTAINER}$"; then
    SDK_RUNNING=true
fi

echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${CYAN}  RealSense D435i Teljes Validáció${NC}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "  Image:   ${RS_IMAGE:-NINCS MEGADVA}"
echo -e "  Log:     ${LOG_FILE}"
echo ""
log "INFO Test start: RS_IMAGE=${RS_IMAGE}, ROS2_IMAGE=${ROS2_IMAGE}"

# ─── TEST 1: Docker daemon ───────────────────────────────────────────────────
echo -e "${BOLD}[1/10] Docker daemon${NC}"
if docker info &>/dev/null; then
    ok "Docker daemon fut"
else
    fail "Docker daemon nem fut — sudo systemctl start docker"
fi

# ─── TEST 2: nvidia runtime ──────────────────────────────────────────────────
echo -e "${BOLD}[2/10] NVIDIA Container Runtime${NC}"
if docker info 2>/dev/null | grep -q nvidia; then
    ok "nvidia runtime konfigurálva"
else
    fail "nvidia runtime hiányzik — nvidia-ctk runtime configure --runtime=docker"
fi

# ─── TEST 3: RealSense USB ───────────────────────────────────────────────────
echo -e "${BOLD}[3/10] RealSense USB csatlakozás${NC}"
if lsusb | grep -qE "8086:0b3a|8086:0b07"; then
    CAM_INFO="$(lsusb | grep -E '8086:0b3a|8086:0b07')"
    ok "RealSense csatlakoztatva: ${CAM_INFO}"
else
    fail "RealSense NEM csatlakoztatva (lsusb nem látja)"
    echo ""
    warn "Maradék tesztek kihagyva (kamera szükséges)"
    echo -e "  ${BOLD}Összesítő: PASS=${PASS} FAIL=${FAIL} WARN=${WARN}${NC}"
    exit 1
fi

# ─── TEST 4: udev rules ──────────────────────────────────────────────────────
echo -e "${BOLD}[4/10] udev Rules${NC}"
if [[ -f /etc/udev/rules.d/99-realsense-libusb.rules ]]; then
    ok "99-realsense-libusb.rules telepítve"
else
    fail "udev rules hiányzik — futtasd: bash install.sh"
fi

# ─── TEST 5: CUDA konténerből ────────────────────────────────────────────────
echo -e "${BOLD}[5/10] CUDA GPU konténerből${NC}"
if [[ -z "${RS_IMAGE}" ]]; then
    warn "RealSense image nem található — kihagyva"
else
    if docker run --rm --runtime=nvidia --network=host \
        -e NVIDIA_VISIBLE_DEVICES=all \
        "${RS_IMAGE}" \
        bash -c "nvidia-smi -L" >> "${LOG_FILE}" 2>&1; then
        GPU_INFO="$(docker run --rm --runtime=nvidia --network=host -e NVIDIA_VISIBLE_DEVICES=all "${RS_IMAGE}" bash -c "nvidia-smi -L" 2>/dev/null || echo 'N/A')"
        ok "GPU: ${GPU_INFO}"
    else
        warn "nvidia-smi sikertelen (Jetson integrált GPU esetén normális)"
    fi
fi

# ─── TEST 6: rs-enumerate-devices ────────────────────────────────────────────
echo -e "${BOLD}[6/10] rs-enumerate-devices${NC}"
if ! ${SDK_RUNNING}; then
    warn "realsense_sdk container nem fut — indítsd: docker compose up -d realsense-sdk"
else
    ENUM_OUT="$(docker exec ${SDK_CONTAINER} rs-enumerate-devices --compact 2>&1 | tee -a "${LOG_FILE}")"
    if echo "${ENUM_OUT}" | grep -qi "Intel RealSense"; then
        ok "rs-enumerate-devices: $(echo "${ENUM_OUT}" | grep -i 'Intel' | head -1)"
    else
        fail "rs-enumerate-devices nem találta a kamerát"
        echo "  Output: $(echo "${ENUM_OUT}" | tail -3)"
    fi
fi

if ${QUICK}; then
    skip "Maradék tesztek (--quick mód)"
    echo ""
    echo -e "${BOLD}Összesítő: ${GREEN}PASS=${PASS}${NC} ${YELLOW}WARN=${WARN}${NC} ${RED}FAIL=${FAIL}${NC}"
    exit $([[ ${FAIL} -eq 0 ]] && echo 0 || echo 1)
fi

# Helper: C++ forrás fordítása és futtatása a realsense_sdk containerben
run_cpp_in_sdk() {
    local src_host="$1"
    local name
    name="$(basename "${src_host}" .cpp)"
    local src_c="/tmp/${name}.cpp"
    local bin_c="/tmp/${name}"
    docker cp "${src_host}" "${SDK_CONTAINER}:${src_c}" 2>/dev/null
    docker exec "${SDK_CONTAINER}" bash -c \
        "g++ -O2 '${src_c}' -o '${bin_c}' \$(pkg-config --cflags --libs realsense2) 2>&1 \
         && '${bin_c}'" 2>&1
    local rc=$?
    docker exec "${SDK_CONTAINER}" rm -f "${src_c}" "${bin_c}" 2>/dev/null || true
    sleep 3
    return ${rc}
}

# ─── TEST 7: IMU stream (accel + gyro) — előbb, mielőtt color/depth megnyitja az eszközt ──
echo -e "${BOLD}[7/10] IMU stream (accel + gyro)${NC}"
if ! ${SDK_RUNNING}; then
    warn "realsense_sdk container nem fut — indítsd: docker compose up -d realsense-sdk"
else
    cat > /tmp/_t7_imu.cpp << 'CPPEOF'
#include <librealsense2/rs.hpp>
#include <iostream>
int main() {
    rs2::pipeline pipe;
    rs2::config cfg;
    cfg.enable_stream(RS2_STREAM_ACCEL, RS2_FORMAT_MOTION_XYZ32F, 63);
    cfg.enable_stream(RS2_STREAM_GYRO,  RS2_FORMAT_MOTION_XYZ32F, 200);
    pipe.start(cfg);
    int accel_ok = 0, gyro_ok = 0;
    for (int i = 0; i < 20; i++) {
        auto frames = pipe.wait_for_frames(5000);
        for (auto&& frame : frames) {
            if (frame.as<rs2::motion_frame>()) {
                if (frame.get_profile().stream_type() == RS2_STREAM_ACCEL) accel_ok++;
                else if (frame.get_profile().stream_type() == RS2_STREAM_GYRO) gyro_ok++;
            }
        }
    }
    pipe.stop();
    std::cout << "Accel frames: " << accel_ok << ", Gyro frames: " << gyro_ok << std::endl;
    return (accel_ok > 0 && gyro_ok > 0) ? 0 : 1;
}
CPPEOF
    IMU_RESULT="$(run_cpp_in_sdk /tmp/_t7_imu.cpp 2>&1 | tee -a "${LOG_FILE}")"
    if echo "${IMU_RESULT}" | grep -qE "Accel frames: [1-9]"; then
        ok "IMU: ${IMU_RESULT}"
    else
        fail "IMU hiba: ${IMU_RESULT}"
    fi
fi

# ─── TEST 8: RGB + Depth stream ──────────────────────────────────────────────
echo -e "${BOLD}[8/10] RGB + Depth stream (10 frame)${NC}"
if ! ${SDK_RUNNING}; then
    warn "realsense_sdk container nem fut"
else
    cat > /tmp/_t8_stream.cpp << 'CPPEOF'
#include <librealsense2/rs.hpp>
#include <iostream>
int main() {
    rs2::pipeline pipe;
    rs2::config cfg;
    cfg.enable_stream(RS2_STREAM_COLOR, 640, 480, RS2_FORMAT_YUYV, 6);
    cfg.enable_stream(RS2_STREAM_DEPTH, 640, 480, RS2_FORMAT_Z16,  6);
    pipe.start(cfg);
    int count = 0;
    for (int i = 0; i < 10; i++) {
        auto frames = pipe.wait_for_frames(10000);
        if (frames.get_color_frame() && frames.get_depth_frame()) count++;
    }
    pipe.stop();
    std::cout << "Frames OK: " << count << "/10" << std::endl;
    return (count == 10) ? 0 : 1;
}
CPPEOF
    STREAM_RESULT="$(run_cpp_in_sdk /tmp/_t8_stream.cpp 2>&1 | tee -a "${LOG_FILE}")"
    if echo "${STREAM_RESULT}" | grep -q "Frames OK: 10/10"; then
        ok "RGB + Depth: 10/10 frame OK"
    else
        fail "RGB/Depth stream hiba: ${STREAM_RESULT}"
    fi
fi

# ─── TEST 9: PointCloud generálás ────────────────────────────────────────────
echo -e "${BOLD}[9/10] PointCloud generálás${NC}"
if ! ${SDK_RUNNING}; then
    warn "realsense_sdk container nem fut"
else
    cat > /tmp/_t9_pc.cpp << 'CPPEOF'
#include <librealsense2/rs.hpp>
#include <iostream>
int main() {
    rs2::pipeline pipe;
    rs2::config cfg;
    cfg.enable_stream(RS2_STREAM_DEPTH, 640, 480, RS2_FORMAT_Z16, 6);
    rs2::pointcloud pc;
    pipe.start(cfg);
    rs2::frameset frames;
    for (int i = 0; i < 5; i++) frames = pipe.wait_for_frames(10000);
    auto depth = frames.get_depth_frame();
    auto points = pc.calculate(depth);
    int n = static_cast<int>(points.size());
    std::cout << "PointCloud pontok: " << n << std::endl;
    pipe.stop();
    return (n > 1000) ? 0 : 1;
}
CPPEOF
    PC_RESULT="$(run_cpp_in_sdk /tmp/_t9_pc.cpp 2>&1 | tee -a "${LOG_FILE}")"
    if echo "${PC_RESULT}" | grep -qE "PointCloud pontok: [1-9]"; then
        ok "PointCloud: ${PC_RESULT}"
    else
        fail "PointCloud hiba: ${PC_RESULT}"
    fi
fi

# ─── TEST 10: Aligned RGBD (depth → color) ───────────────────────────────────
echo -e "${BOLD}[10/10] Aligned RGBD (depth→color igazítás)${NC}"
if ! ${SDK_RUNNING}; then
    warn "realsense_sdk container nem fut"
else
    cat > /tmp/_t10_align.cpp << 'CPPEOF'
#include <librealsense2/rs.hpp>
#include <iostream>
#include <iomanip>
int main() {
    rs2::pipeline pipe;
    rs2::config cfg;
    cfg.enable_stream(RS2_STREAM_COLOR, 640, 480, RS2_FORMAT_YUYV, 6);
    cfg.enable_stream(RS2_STREAM_DEPTH, 640, 480, RS2_FORMAT_Z16,  6);
    rs2::align align(RS2_STREAM_COLOR);
    pipe.start(cfg);
    rs2::frameset frames;
    for (int i = 0; i < 5; i++) frames = pipe.wait_for_frames(10000);
    auto aligned = align.process(frames);
    auto color   = aligned.get_color_frame();
    auto depth   = aligned.get_depth_frame();
    int cw = color.get_width(), ch = color.get_height();
    int dw = depth.get_width(), dh = depth.get_height();
    float dist = depth.get_distance(dw / 2, dh / 2);
    std::cout << "Color: " << cw << "x" << ch
              << ", Depth (aligned): " << dw << "x" << dh
              << ", Közép: " << std::fixed << std::setprecision(3) << dist << "m"
              << std::endl;
    pipe.stop();
    return (cw > 0 && dw > 0) ? 0 : 1;
}
CPPEOF
    ALIGN_RESULT="$(run_cpp_in_sdk /tmp/_t10_align.cpp 2>&1 | tee -a "${LOG_FILE}")"
    if echo "${ALIGN_RESULT}" | grep -q "Color:"; then
        ok "Aligned RGBD: ${ALIGN_RESULT}"
    else
        fail "Aligned RGBD hiba: ${ALIGN_RESULT}"
    fi
fi

# ─── ROS2 teszt (opcionális) ─────────────────────────────────────────────────
if ${TEST_ROS2} && [[ -n "${ROS2_IMAGE}" ]]; then
    echo -e "${BOLD}[+] ROS2 topicok (10 másodperc várakozás)${NC}"
    if docker ps | grep -q ros2_realsense; then
        TOPICS="$(docker exec ros2_realsense bash -c \
            'source /opt/ros/jazzy/setup.bash && ros2 topic list 2>/dev/null')"
        for expected_topic in \
            "/camera/color/image_raw" \
            "/camera/depth/image_rect_raw" \
            "/camera/imu" \
            "/camera/depth/color/points"; do
            if echo "${TOPICS}" | grep -qF "${expected_topic}"; then
                ok "ROS2 topic: ${expected_topic}"
            else
                warn "ROS2 topic hiányzik: ${expected_topic}"
            fi
        done
    else
        warn "ros2_realsense konténer nem fut — indítsd: docker compose up -d ros2-realsense"
    fi
fi

# ─── Összesítő ───────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Validáció összesítő${NC}"
echo -e "  ${GREEN}PASS: ${PASS}${NC}  ${YELLOW}WARN: ${WARN}${NC}  ${RED}FAIL: ${FAIL}${NC}"
echo -e "  Log: ${LOG_FILE}"
echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
echo ""

log "SUMMARY Pass=${PASS} Warn=${WARN} Fail=${FAIL}"
exit $([[ ${FAIL} -eq 0 ]] && echo 0 || echo 1)
