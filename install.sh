#!/bin/bash
# =============================================================================
# RealSense D435i + Jetson Orin Nano (JetPack 6.2 / L4T R36.4.x)
# Automated Docker Installer
# =============================================================================
# Futtatás: bash install.sh
# Újrafuttatható (idempotent) — minden lépés ellenőrzi ha már elvégezve
# =============================================================================

set -euo pipefail

# ── Konfiguráció ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${SCRIPT_DIR}/logs"
LOG_FILE="${LOG_DIR}/install_${TIMESTAMP}.log"
LATEST_LOG="${LOG_DIR}/install_latest.log"

# L4T verzió a base image tag-hez (automatikusan detektálva később)
L4T_TAG=""
REALSENSE_IMAGE="realsense-sdk:2.56.5"
ROS2_IMAGE=""

# ── Színek ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Log + Output függvények ───────────────────────────────────────────────────
mkdir -p "${LOG_DIR}"

log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${msg}" >> "${LOG_FILE}"
    ln -sf "${LOG_FILE}" "${LATEST_LOG}"
}

info() {
    log "INFO" "$*"
    echo -e "${BLUE}[INFO]${NC} $*"
}

ok() {
    log "OK" "$*"
    echo -e "${GREEN}[OK]${NC}   $*"
}

warn() {
    log "WARN" "$*"
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    log "ERROR" "$*"
    echo -e "${RED}[ERR]${NC}  $*" >&2
}

section() {
    local msg="$*"
    log "SECTION" "=== ${msg} ==="
    echo ""
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  ${msg}${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════════════════${NC}"
}

step() {
    log "STEP" "$*"
    echo -e "  ${YELLOW}▶${NC} $*"
}

skip() {
    log "SKIP" "$*"
    echo -e "  ${GREEN}✓${NC} $* ${YELLOW}(már kész, kihagyva)${NC}"
}

fail() {
    log "FAIL" "$*"
    echo -e "${RED}[FAIL]${NC} $*" >&2
    echo ""
    echo -e "${RED}══════════════════════════════════════════════════${NC}"
    echo -e "${RED}  TELEPÍTÉS MEGSZAKADT — Hibanapló:${NC}"
    echo -e "${RED}  ${LOG_FILE}${NC}"
    echo -e "${RED}══════════════════════════════════════════════════${NC}"
    exit 1
}

run() {
    log "RUN" "$*"
    if ! "$@" >> "${LOG_FILE}" 2>&1; then
        error "Parancs sikertelen: $*"
        error "Részletek: tail -50 ${LOG_FILE}"
        fail "Álljon le a telepítés"
    fi
}

run_show() {
    # Parancs futtatása logba ÉS terminálra egyidejűleg
    log "RUN_SHOW" "$*"
    "$@" 2>&1 | tee -a "${LOG_FILE}"
    return "${PIPESTATUS[0]}"
}

# ── Fejléc ───────────────────────────────────────────────────────────────────
print_header() {
    clear
    echo -e "${BOLD}${CYAN}"
    cat << 'EOF'
  ██████╗ ███████╗ █████╗ ██╗     ███████╗███████╗███╗   ██╗███████╗███████╗
  ██╔══██╗██╔════╝██╔══██╗██║     ██╔════╝██╔════╝████╗  ██║██╔════╝██╔════╝
  ██████╔╝█████╗  ███████║██║     ███████╗█████╗  ██╔██╗ ██║███████╗█████╗
  ██╔══██╗██╔══╝  ██╔══██║██║     ╚════██║██╔══╝  ██║╚██╗██║╚════██║██╔══╝
  ██║  ██║███████╗██║  ██║███████╗███████║███████╗██║ ╚████║███████║███████╗
  ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═══╝╚══════╝╚══════╝
EOF
    echo -e "${NC}"
    echo -e "${BOLD}  Intel RealSense D435i Docker Telepítő${NC}"
    echo -e "  Jetson Orin Nano · JetPack 6.2 · L4T R36.4.x · CUDA 12.6"
    echo ""
    echo -e "  Log fájl: ${CYAN}${LOG_FILE}${NC}"
    echo -e "  Valós idejű log: ${CYAN}tail -f ${LOG_FILE}${NC}"
    echo ""
    log "INFO" "Telepítő indítva — $(uname -a)"
    log "INFO" "Log: ${LOG_FILE}"
}

# ── Előfeltételek ellenőrzése ─────────────────────────────────────────────────
check_prerequisites() {
    section "Előfeltételek ellenőrzése"

    # Root-e?
    if [[ $EUID -eq 0 ]]; then
        fail "Ne futtasd root-ként! Futtasd: bash install.sh (sudo nélkül)"
    fi
    ok "Nem root felhasználó: $(whoami)"

    # Jetson-e?
    local model
    model="$(cat /proc/device-tree/model 2>/dev/null || echo 'unknown')"
    log "INFO" "Hardver modell: ${model}"
    if [[ "${model}" != *"Jetson"* ]] && [[ "${model}" != *"NVIDIA"* ]]; then
        warn "Nem Jetson hardver: ${model}"
        warn "A telepítés csak Jetson Orin Nano-ra lett tesztelve!"
    else
        ok "Jetson hardver: ${model}"
    fi

    # L4T verzió
    if [[ -f /etc/nv_tegra_release ]]; then
        local l4t_info
        l4t_info="$(grep -m1 'R' /etc/nv_tegra_release)"
        log "INFO" "L4T: ${l4t_info}"

        # Major.Minor kiolvasása
        local l4t_major l4t_minor
        l4t_major="$(grep -oP 'R\K[0-9]+' /etc/nv_tegra_release | head -1)"
        l4t_minor="$(grep -oP 'REVISION: \K[0-9]+\.[0-9]+' /etc/nv_tegra_release | head -1)"
        L4T_TAG="r${l4t_major}.${l4t_minor%.*}.0"
        ok "L4T verzió: R${l4t_major}.${l4t_minor} → Image tag: ${L4T_TAG}"
        log "INFO" "L4T_TAG=${L4T_TAG}"
    else
        warn "Nem található /etc/nv_tegra_release — L4T R36.4 feltételezve"
        L4T_TAG="r36.4.0"
    fi

    # JetPack
    local jp_ver
    jp_ver="$(dpkg -l nvidia-jetpack 2>/dev/null | grep '^ii' | awk '{print $3}' || echo 'n/a')"
    ok "JetPack: ${jp_ver}"

    # CUDA
    if command -v nvcc &>/dev/null; then
        local cuda_ver
        cuda_ver="$(nvcc --version | grep -oP 'release \K[0-9.]+' | head -1)"
        ok "CUDA: ${cuda_ver}"
        log "INFO" "CUDA: ${cuda_ver}"
    else
        warn "nvcc nem elérhető PATH-ban"
    fi

    # Ubuntu verzió
    local ubuntu_ver
    ubuntu_ver="$(lsb_release -rs 2>/dev/null || echo 'unknown')"
    ok "Ubuntu: ${ubuntu_ver}"

    # Internet kapcsolat
    step "Internet kapcsolat ellenőrzése..."
    if ! curl -s --max-time 5 https://google.com -o /dev/null; then
        fail "Nincs internet kapcsolat! A telepítéshez szükséges."
    fi
    ok "Internet kapcsolat OK"

    # RealSense kamera csatlakoztatva?
    step "RealSense kamera keresése..."
    if lsusb | grep -q "8086:0b3a\|8086:0b07\|8086:0b64\|8086:0ace\|8086:0acf"; then
        local cam_info
        cam_info="$(lsusb | grep -E "8086:0b3a|8086:0b07|8086:0b64|8086:0ace|8086:0acf")"
        ok "RealSense kamera: ${cam_info}"
        log "INFO" "RealSense: ${cam_info}"
    else
        warn "RealSense kamera NEM csatlakoztatva (USB-n nem látható)"
        warn "A kamera nélkül is folytatható a telepítés, de a validáció sikertelen lesz"
    fi

    log "INFO" "Előfeltételek ellenőrzése kész"
}

# ── 1. FÁZIS: Docker telepítés ─────────────────────────────────────────────────
install_docker() {
    section "1. Fázis: Docker Engine telepítés"

    if command -v docker &>/dev/null; then
        local docker_ver
        docker_ver="$(docker --version)"
        skip "Docker már telepítve: ${docker_ver}"
        log "INFO" "Docker skip: ${docker_ver}"
        return 0
    fi

    step "Docker CE telepítése (ARM64 / Ubuntu 22.04)..."

    run sudo apt-get update -qq
    run sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    step "Docker GPG kulcs hozzáadása..."
    run sudo install -m 0755 -d /etc/apt/keyrings
    run bash -c "curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg"
    run sudo chmod a+r /etc/apt/keyrings/docker.gpg

    step "Docker repository hozzáadása..."
    run bash -c "echo \"deb [arch=arm64 signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null"

    step "Docker csomagok telepítése..."
    run sudo apt-get update -qq
    run sudo apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    step "Docker service engedélyezése..."
    run sudo systemctl enable docker
    run sudo systemctl start docker

    step "Felhasználó hozzáadása docker csoporthoz..."
    run sudo usermod -aG docker "${USER}"

    # ── Jetson L4T kernel kompatibilitás: iptables-nft ──────────────────
    # Docker 27+ "Direct Access Filtering" az iptable_raw modult igényli,
    # ami a Jetson OOT kernelben nem elérhető. Megoldás: iptables-nft.
    step "iptables kompatibilitás ellenőrzése (Jetson L4T)..."
    if [[ -x /usr/sbin/iptables-nft ]]; then
        local current_iptables
        current_iptables="$(readlink -f /usr/sbin/iptables 2>/dev/null || echo '')"
        if [[ "${current_iptables}" != *"nft"* ]]; then
            step "Átváltás iptables-nft-re (Jetson L4T kernel kompatibilitás)..."
            run sudo update-alternatives --set iptables /usr/sbin/iptables-nft
            run sudo update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
            run sudo systemctl restart docker
            ok "iptables → iptables-nft (Docker Direct Access Filtering fix)"
            log "INFO" "iptables-nft beállítva"
        else
            skip "iptables-nft már aktív"
        fi
    else
        warn "iptables-nft nem elérhető — Docker networking problémák lehetségesek"
    fi

    # Ellenőrzés
    if ! sudo docker run --rm hello-world >> "${LOG_FILE}" 2>&1; then
        fail "Docker telepítés sikertelen — lásd: ${LOG_FILE}"
    fi

    ok "Docker telepítve: $(sudo docker --version)"
    warn "FONTOS: Jelentkezz ki és be a 'docker' csoport aktiválásához!"
    warn "         Vagy futtasd: newgrp docker"
    log "INFO" "Docker telepítés kész"
}

# ── 2. FÁZIS: NVIDIA Container Toolkit ─────────────────────────────────────────
install_nvidia_container_toolkit() {
    section "2. Fázis: NVIDIA Container Toolkit"

    # Ellenőrzés: nvidia-ctk bináris jelenléte (JetPack is tartalmazza)
    if command -v nvidia-ctk &>/dev/null; then
        local nctk_ver
        nctk_ver="$(nvidia-ctk --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+'| head -1)"
        skip "nvidia-container-toolkit már telepítve: v${nctk_ver} (JetPack vagy korábbi telepítés)"
        log "INFO" "nvidia-container-toolkit skip: v${nctk_ver}"

        # Runtime konfiguráció ellenőrzése
        if ! sudo docker info 2>/dev/null | grep -q nvidia; then
            step "nvidia-ctk runtime konfigurálás..."
            run sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
            run sudo systemctl restart docker
            ok "nvidia runtime konfigurálva"
        else
            skip "nvidia runtime már konfigurálva"
        fi
        return 0
    fi

    step "NVIDIA Container Toolkit GPG kulcs..."
    run bash -c "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor --yes \
        -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"

    step "NVIDIA Container Toolkit repository..."
    run bash -c "curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null"

    step "nvidia-container-toolkit telepítése..."
    run sudo apt-get update -qq
    # --allow-downgrades: ha a repo régebbi verziót tartalmaz mint a JetPack
    run sudo apt-get install -y -qq --allow-downgrades nvidia-container-toolkit

    step "Docker runtime konfigurálás (nvidia = default)..."
    run sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
    run sudo systemctl restart docker

    # Teszt
    step "GPU elérhetőség tesztelése konténerből..."
    if sudo docker run --rm --runtime=nvidia \
        -e NVIDIA_VISIBLE_DEVICES=all \
        nvcr.io/nvidia/l4t-base:"${L4T_TAG}" \
        nvidia-smi >> "${LOG_FILE}" 2>&1; then
        ok "CUDA GPU elérhető konténerből"
    else
        warn "nvidia-smi teszt sikertelen (l4t-base pull vagy GPU hiba)"
        warn "Részletek: tail -30 ${LOG_FILE}"
    fi

    ok "nvidia-container-toolkit telepítve"
    log "INFO" "nvidia-container-toolkit kész"
}

# ── 3. FÁZIS: RealSense udev rules (HOST) ─────────────────────────────────────
install_udev_rules() {
    section "3. Fázis: RealSense udev Rules (HOST)"

    info "Ez az egyetlen dolog ami natívan kell — kernel USB jogosultság"

    local rules_file="/etc/udev/rules.d/99-realsense-libusb.rules"

    if [[ -f "${rules_file}" ]]; then
        skip "RealSense udev rules már telepítve: ${rules_file}"
        log "INFO" "udev rules skip"
        return 0
    fi

    step "99-realsense-libusb.rules letöltése..."
    run curl -fsSL \
        "https://raw.githubusercontent.com/IntelRealSense/librealsense/master/config/99-realsense-libusb.rules" \
        -o /tmp/99-realsense-libusb.rules

    step "Rules telepítése /etc/udev/rules.d/-be..."
    run sudo cp /tmp/99-realsense-libusb.rules "${rules_file}"
    run sudo chmod 644 "${rules_file}"

    step "udev reload..."
    run sudo udevadm control --reload-rules
    run sudo udevadm trigger

    ok "RealSense udev rules telepítve: ${rules_file}"

    # Ellenőrzés
    if lsusb | grep -q "8086:0b3a"; then
        step "USB node jogosultság ellenőrzése..."
        local usb_bus usb_dev
        usb_bus="$(lsusb | grep '8086:0b3a' | grep -oP 'Bus \K[0-9]+')"
        usb_dev="$(lsusb | grep '8086:0b3a' | grep -oP 'Device \K[0-9]+')"
        local usb_path="/dev/bus/usb/${usb_bus}/${usb_dev}"
        if [[ -r "${usb_path}" ]]; then
            ok "USB node olvasható: ${usb_path}"
        else
            warn "USB node jogosultság probléma: ${usb_path}"
            warn "Futtasd: sudo udevadm trigger --action=add"
        fi
    fi

    log "INFO" "udev rules kész"
}


# ── 4. FÁZIS: RealSense SDK image (librealsense 2.56.5, RSUSB backend) ────────
build_realsense_image() {
    section "4. Fázis: librealsense2 SDK Image (2.56.5)"

    # Már megvan lokálisan?
    if sudo docker images --format "{{.Repository}}:{{.Tag}}" \
            | grep -qF "${REALSENSE_IMAGE}"; then
        skip "realsense-sdk image már létezik: ${REALSENSE_IMAGE}"
        log "INFO" "realsense image skip: ${REALSENSE_IMAGE}"
        return 0
    fi

    info "librealsense 2.56.5 fordítása forrásból (RSUSB backend)"
    info "Várható idő: ~30-40 perc (ARM64, $(nproc) mag)"
    info "Valós idejű log: tail -f ${LOG_FILE}"

    step "Docker build: ${REALSENSE_IMAGE} ..."
    if ! sudo docker build \
        --network=host \
        -t "${REALSENSE_IMAGE}" \
        "${SCRIPT_DIR}/realsense-sdk/" >> "${LOG_FILE}" 2>&1; then
        fail "realsense-sdk image build sikertelen — részletek: ${LOG_FILE}"
    fi

    ok "realsense-sdk image kész: ${REALSENSE_IMAGE}"
    log "INFO" "realsense build OK: ${REALSENSE_IMAGE}"
}

# ── 6. FÁZIS: ROS2 + RealSense image ──────────────────────────────────────────
build_ros2_realsense_image() {
    section "6. Fázis: ROS2 Jazzy + realsense2_camera Image"

    # Lehetséges tag variációk (Jazzyhoz nincs dustynv pre-built)
    local candidates=(
        "ros2-realsense:${L4T_TAG}"
    )

    # Már megvan lokálisan?
    for img in "${candidates[@]}"; do
        if sudo docker images --format "{{.Repository}}:{{.Tag}}" | grep -qF "${img}" 2>/dev/null || false; then
            skip "ROS2+realsense image már létezik: ${img}"
            ROS2_IMAGE="${img}"
            log "INFO" "ROS2 image skip: ${img}"
            return 0
        fi
    done

    # ROS2 Jazzy + realsense2_camera Dockerfile buildelés (ubuntu:24.04 alapon)
    step "realsense2_camera ROS2 Jazzy node image buildelés..."
    info "Ez ~15-25 percig tarthat (ubuntu:24.04 + ROS2 Jazzy + realsense2_camera)"

    local ros2_rs_dir="${SCRIPT_DIR}/ros2-realsense"
    mkdir -p "${ros2_rs_dir}"

    cat > "${ros2_rs_dir}/Dockerfile" << DOCKERFILE_EOF
# ROS2 Jazzy + realsense2_camera node
# Ubuntu 24.04 (Noble) alapon — fut Jetson 22.04-es hoston Dockerben
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=jazzy
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all,compute,video,utility

# Alap csomagok + ROS2 Jazzy repo
RUN apt-get update && apt-get install -y --no-install-recommends \\
    curl gnupg2 lsb-release ca-certificates \\
    && mkdir -p /etc/apt/keyrings \\
    && curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \\
       | gpg --dearmor -o /etc/apt/keyrings/ros-archive-keyring.gpg \\
    && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/ros-archive-keyring.gpg] \\
       http://packages.ros.org/ros2/ubuntu noble main" \\
       | tee /etc/apt/sources.list.d/ros2.list \\
    && apt-get update && apt-get install -y --no-install-recommends \\
       ros-jazzy-ros-base \\
       ros-jazzy-realsense2-camera \\
       ros-jazzy-realsense2-description \\
       ros-jazzy-image-transport \\
       ros-jazzy-cv-bridge \\
       ros-jazzy-tf2-ros \\
       ros-jazzy-diagnostic-updater \\
       python3-colcon-common-extensions \\
       python3-rosdep \\
    && rm -rf /var/lib/apt/lists/*

# Intel RealSense apt repo (Noble/Ubuntu 24.04, arm64)
RUN mkdir -p /etc/apt/keyrings \\
    && curl -sSf https://librealsense.realsenseai.com/Debian/librealsenseai.asc \\
       | gpg --dearmor | tee /etc/apt/keyrings/librealsenseai.gpg > /dev/null \\
    && echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/librealsenseai.gpg] https://librealsense.realsenseai.com/Debian/apt-repo noble main" \\
       | tee /etc/apt/sources.list.d/librealsense.list \\
    && apt-get update \\
    && apt-get install -y --no-install-recommends \\
       librealsense2 librealsense2-utils librealsense2-dev \\
    || true \\
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["ros2", "launch", "realsense2_camera", "rs_launch.py", \\
     "enable_rgbd:=true", \\
     "enable_sync:=true", \\
     "align_depth.enable:=true", \\
     "enable_color:=true", \\
     "enable_depth:=true", \\
     "enable_accel:=true", \\
     "enable_gyro:=true", \\
     "unite_imu_method:=2", \\
     "pointcloud.enable:=true", \\
     "depth_module.depth_profile:=640x480x30", \\
     "rgb_camera.color_profile:=1280x720x30"]
DOCKERFILE_EOF

    cat > "${ros2_rs_dir}/entrypoint.sh" << 'ENTRY_EOF'
#!/bin/bash
source /opt/ros/jazzy/setup.bash
exec "$@"
ENTRY_EOF

    run sudo docker build --network=host -t "ros2-realsense:${L4T_TAG}" "${ros2_rs_dir}"

    ROS2_IMAGE="ros2-realsense:${L4T_TAG}"
    ok "ROS2+realsense image kész: ${ROS2_IMAGE}"
    log "INFO" "ROS2 image kész: ${ROS2_IMAGE}"
}



# ── 9. FÁZIS: Szkriptek létrehozása ────────────────────────────────────────────
create_scripts() {
    section "9. Fázis: Kényelmi szkriptek"

    # start.sh
    cat > "${SCRIPT_DIR}/scripts/start.sh" << 'SCRIPT_EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
echo "RealSense stack indítása..."
docker compose up -d
echo ""
echo "Státusz:"
docker compose ps
echo ""
echo "Logs (Ctrl+C kilépéshez):"
echo "  docker compose logs -f ros2-realsense"
SCRIPT_EOF

    # stop.sh
    cat > "${SCRIPT_DIR}/scripts/stop.sh" << 'SCRIPT_EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
echo "RealSense stack leállítása..."
docker compose down
SCRIPT_EOF

    # status.sh
    cat > "${SCRIPT_DIR}/scripts/status.sh" << 'SCRIPT_EOF'
#!/bin/bash
cd "$(dirname "$0")/.."
echo "=== Konténer státusz ==="
docker compose ps
echo ""
echo "=== GPU memória ==="
docker exec realsense_sdk nvidia-smi 2>/dev/null || echo "SDK konténer nem fut"
echo ""
echo "=== ROS2 topicok ==="
docker exec ros2_realsense bash -c \
    "source /opt/ros/jazzy/setup.bash && ros2 topic list 2>/dev/null" \
    2>/dev/null || echo "ROS2 konténer nem fut"
SCRIPT_EOF

    chmod +x "${SCRIPT_DIR}/scripts/"*.sh
    ok "Szkriptek létrehozva: start.sh, stop.sh, status.sh"
    log "INFO" "Szkriptek kész"
}

# ── 10. FÁZIS: Validáció ───────────────────────────────────────────────────────
# ── 7. FÁZIS: Validáció ────────────────────────────────────────────────────────
run_validation() {
    section "7. Fázis: Validáció"

    local passed=0
    local failed=0
    local warnings=0

    # Teszt 1: Docker daemon
    step "Teszt 1/5: Docker daemon..."
    if sudo docker info &>/dev/null; then
        ok "Docker daemon fut"
        ((passed++)) || true
    else
        error "Docker daemon nem fut"
        ((failed++)) || true
    fi

    # Teszt 2: NVIDIA runtime
    step "Teszt 2/5: NVIDIA runtime..."
    if sudo docker info 2>/dev/null | grep -q nvidia; then
        ok "nvidia runtime konfigurálva"
        ((passed++)) || true
    else
        warn "nvidia runtime nem található — ellenőrizd az nvidia-container-toolkit-et"
        ((warnings++)) || true
    fi

    # Teszt 3: realsense-sdk image létezik-e
    step "Teszt 3/5: realsense-sdk image..."
    if sudo docker images --format "{{.Repository}}:{{.Tag}}" \
            | grep -qF "${REALSENSE_IMAGE}"; then
        ok "Image megvan: ${REALSENSE_IMAGE}"
        ((passed++)) || true
    else
        error "Image hiányzik: ${REALSENSE_IMAGE}"
        ((failed++)) || true
    fi

    # Teszt 4: RealSense USB eszköz
    step "Teszt 4/5: RealSense USB eszköz..."
    if lsusb | grep -qE "8086:0b3a|8086:0b07"; then
        local cam_info
        cam_info="$(lsusb | grep -E '8086:0b3a|8086:0b07')"
        ok "RealSense csatlakoztatva: ${cam_info}"
        ((passed++)) || true
    else
        warn "RealSense nem csatlakoztatva — 5/5 teszt kihagyva"
        ((warnings++)) || true
        log "TEST4" "RealSense nem csatlakoztatva"
    fi

    # Teszt 5: rs-enumerate-devices a futó realsense_sdk containerből
    step "Teszt 5/5: rs-enumerate-devices (realsense_sdk container)..."
    if sudo docker ps --format "{{.Names}}" 2>/dev/null | grep -q "^realsense_sdk$"; then
        local enum_out
        enum_out="$(sudo docker exec realsense_sdk rs-enumerate-devices --compact 2>&1 \
                    | tee -a "${LOG_FILE}")"
        if echo "${enum_out}" | grep -qi "Intel RealSense"; then
            local fw_ver
            fw_ver="$(echo "${enum_out}" | grep -i "Firmware Version" | awk '{print $NF}' | head -1)"
            ok "rs-enumerate-devices OK — Firmware: ${fw_ver}"
            ((passed++)) || true
        else
            warn "rs-enumerate-devices: kamera nem látható — USB kábel/udev ellenőrzés"
            ((warnings++)) || true
        fi
    else
        warn "realsense_sdk container nem fut — indítsd: docker compose up -d realsense-sdk"
        ((warnings++)) || true
    fi

    # Összesítő
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Validáció eredmény${NC}"
    echo -e "  ${GREEN}Sikeres: ${passed}${NC}"
    echo -e "  ${YELLOW}Figyelmeztetés: ${warnings}${NC}"
    echo -e "  ${RED}Sikertelen: ${failed}${NC}"
    echo -e "  Részletes: bash scripts/test_realsense.sh"
    echo -e "${BOLD}══════════════════════════════════════════════════${NC}"

    log "VALIDATION" "Pass: ${passed}, Warn: ${warnings}, Fail: ${failed}"

    if [[ ${failed} -gt 0 ]]; then
        error "Kritikus hibák — lásd: ${LOG_FILE}"
        return 1
    fi

    ok "Validáció kész"
}

# ── Összesítő ────────────────────────────────────────────────────────────────
print_summary() {
    section "Telepítés összesítő"

    echo -e "${BOLD}  Natívan telepített (host):${NC}"
    echo -e "  • Docker Engine $(docker --version 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+')"
    echo -e "  • nvidia-container-toolkit"
    echo -e "  • RealSense udev rules"
    echo ""
    echo -e "${BOLD}  Docker image-ek:${NC}"
    sudo docker images --format "  • {{.Repository}}:{{.Tag}} ({{.Size}})" | grep -E "realsense|ros2|l4t" | head -10 || true
    echo ""
    echo -e "${BOLD}  Hasznos parancsok:${NC}"
    echo -e "  ${CYAN}cd ${SCRIPT_DIR}${NC}"
    echo -e "  ${CYAN}docker compose up -d${NC}               # Stack indítás"
    echo -e "  ${CYAN}docker compose logs -f ros2-realsense${NC} # ROS2 log"
    echo -e "  ${CYAN}bash scripts/test_realsense.sh${NC}     # Teljes teszt"
    echo -e "  ${CYAN}bash scripts/status.sh${NC}             # Státusz"
    echo ""
    echo -e "  ${BOLD}Log fájl:${NC} ${LOG_FILE}"
    echo -e "  ${BOLD}Latest log:${NC} ${LATEST_LOG}"
    echo ""

    log "SUMMARY" "Telepítés befejezve: $(date)"
    log "SUMMARY" "Log: ${LOG_FILE}"
    log "SUMMARY" "REALSENSE_IMAGE: ${REALSENSE_IMAGE}"
    log "SUMMARY" "ROS2_IMAGE: ${ROS2_IMAGE}"
    log "SUMMARY" "L4T_TAG: ${L4T_TAG}"
}

# ── Log ablak megnyitása ──────────────────────────────────────────────────────
open_log_window() {
    local title="RealSense Telepítő — Log"
    local cmd="tail -f '${LOG_FILE}'"

    if command -v gnome-terminal &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
        gnome-terminal \
            --title="${title}" \
            --geometry=120x35 \
            -- bash -c "${cmd}; echo '--- log vége ---'; read" \
            &>/dev/null & disown
    elif command -v xterm &>/dev/null && [[ -n "${DISPLAY:-}" ]]; then
        xterm -title "${title}" -geometry 120x35 \
            -e "bash -c \"${cmd}; echo '--- log vége ---'; read\"" \
            &>/dev/null & disown
    else
        info "Log ablak nem nyitható (nincs display/terminal) — kövesd: tail -f ${LOG_FILE}"
    fi
}

# ── Főprogram ─────────────────────────────────────────────────────────────────
main() {
    print_header

    # Log ablak megnyitása a háttérben
    open_log_window

    # Elvégzett lépések logolása
    log "INFO" "Telepítés kezdete: $(date)"
    log "INFO" "Felhasználó: $(whoami)"
    log "INFO" "Munkakönyvtár: ${SCRIPT_DIR}"

    check_prerequisites           # 1. előfeltételek (git, curl, stb.)
    install_docker                # 2. Docker Engine
    install_nvidia_container_toolkit  # 3. nvidia-container-toolkit
    install_udev_rules            # 4. RealSense udev rules
    build_realsense_image         # 5. realsense-sdk:2.56.5 image build (~30 perc)
    build_ros2_realsense_image    # 6. ROS2 Jazzy + realsense2_camera
    create_scripts                # 7. kényelmi szkriptek (start/stop/status)
    run_validation                # 8. validáció
    print_summary

    echo ""
    echo -e "${BOLD}${GREEN}  ✓ TELEPÍTÉS KÉSZ!${NC}"
    echo ""
}

main "$@"
