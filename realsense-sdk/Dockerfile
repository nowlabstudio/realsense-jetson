# =============================================================================
# Intel RealSense SDK 2.56.5 — Jetson Orin Nano (ARM64)
# Ubuntu 22.04 Jammy | RSUSB backend | C++ fejlesztési környezet
#
# MIÉRT FORRÁSBÓL FORDÍTJUK:
#   Az hivatalos ARM64 apt csomag V4L2 backendel épül, ami kernel modult igényel.
#   Docker containerben kernel modul nem érhető el, ezért RSUSB backend kell
#   (-DFORCE_RSUSB_BACKEND=ON), amit csak forrásból lehet bekonfigurálni.
#
# Build:
#   docker build --network=host -t realsense-sdk:2.56.5 realsense-sdk/
#
# Várható build idő: ~25-40 perc (ARM64, 6 mag)
# =============================================================================

# ─── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ARG LIBREALSENSE_VERSION=v2.56.5
ARG BUILD_JOBS=0
# BUILD_JOBS=0 → cmake automatikusan meghatározza (nproc)

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Budapest

# Build dependenciák — csak a fordításhoz szükségesek
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Fordítói lánc
    build-essential \
    cmake \
    git \
    pkg-config \
    # SSL / hálózat
    ca-certificates \
    curl \
    # USB — RSUSB backend kötelező dep
    libusb-1.0-0-dev \
    libudev-dev \
    # librealsense belső dependenciák
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# librealsense forrás letöltése — csak a szükséges mélység (1 commit)
RUN git clone \
    --depth 1 \
    --branch ${LIBREALSENSE_VERSION} \
    https://github.com/realsenseai/librealsense.git \
    /opt/librealsense

# CMake konfiguráció
# Fontosabb kapcsolók magyarázata:
#   FORCE_RSUSB_BACKEND=ON   → libusb közvetlen USB elérés, kernel modul nem kell
#   BUILD_EXAMPLES=OFF       → GUI demo példák kihagyva (nincs display a containerben)
#   BUILD_GRAPHICAL_EXAMPLES=OFF → OpenGL/GLFW nem szükséges
#   BUILD_TOOLS=ON           → rs-enumerate-devices, rs-fw-update, rs-depth, stb.
#   BUILD_PYTHON_BINDINGS=OFF → C++ fókusz, Python binding nem kell
#   BUILD_SHARED_LIBS=ON     → .so könyvtár, statikus linkelés helyett
#   CMAKE_BUILD_TYPE=Release → optimalizált, debug szimbólumok nélkül
#
# Teljesítmény flagek (Jetson Orin Nano — Cortex-A78AE, ARMv8.2-A):
#   -O3             → Release default -O2 felett: loop unrolling, auto-vectorization
#   -march=native   → Cortex-A78AE NEON/SIMD/dotprod intrinsics (build gépen detektált)
#   -fno-plt        → PLT ugrások eliminálása .so hívásoknál (~1-2% latency)
#   LTO             → Link-time optimization: cross-TU inlining, dead code removal
RUN cmake \
    -S /opt/librealsense \
    -B /opt/librealsense/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=native -fno-plt" \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=native -fno-plt" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DFORCE_RSUSB_BACKEND=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_GRAPHICAL_EXAMPLES=OFF \
    -DBUILD_TOOLS=ON \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_UNITY_BINDINGS=OFF \
    -DBUILD_WITH_CUDA=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX=/opt/rs-install

# Fordítás és telepítés az /opt/rs-install prefix alá
# A BUILD_JOBS=0 esetén cmake maga használja az összes magot
RUN cmake --build /opt/librealsense/build \
    --config Release \
    --parallel $([ "${BUILD_JOBS}" = "0" ] && nproc || echo "${BUILD_JOBS}") \
    && cmake --install /opt/librealsense/build


# =============================================================================
# ─── Stage 2: Runtime ─────────────────────────────────────────────────────────
# Lefordított SDK artifact-ok + C++ fejlesztési toolchain
# git és a librealsense forrás NEM kerül ide — csak a kész .so + headerek
# =============================================================================
FROM ubuntu:22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Budapest

# Runtime dependenciák + C++ fejlesztési toolchain
# A gcc/cmake szándékosan benne van: a user C++ alkalmazásokat fejleszt a containerben
RUN apt-get update && apt-get install -y --no-install-recommends \
    # C++ fejlesztési toolchain
    build-essential \
    cmake \
    pkg-config \
    # Runtime USB elérés — RSUSB backend
    libusb-1.0-0 \
    libudev1 \
    # usbutils: lsusb és egyéb USB diagnosztika
    usbutils \
    # SSL runtime
    libssl3 \
    # Debug eszközök
    strace \
    && rm -rf /var/lib/apt/lists/*

# Lefordított SDK bemásolása a builder stage-ből
COPY --from=builder /opt/rs-install /usr/local

# Dinamikus linker frissítése az új .so fájlok miatt
RUN ldconfig

# Fejlesztési könnyítés: cmake find_package(realsense2) működjön
ENV CMAKE_PREFIX_PATH=/usr/local

# NVIDIA Container Runtime változók
# (nvidia-container-toolkit injektálja a CUDA library-kat futáskor)
ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all

# Ellenőrzés: a binary elérhető és fut
RUN rs-enumerate-devices --version \
    && echo "=== librealsense build ellenőrzés OK ===" \
    && ldd /usr/local/bin/rs-enumerate-devices | grep -i realsense

# Healthcheck: rs-enumerate-devices visszatér (kamera nélkül is 0-val tér vissza
# ha az SDK rendben van, 1-gyel ha az SDK hibás)
HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=15s \
    CMD rs-enumerate-devices --compact || exit 1

# Default: fut a háttérben, docker exec -it realsense_sdk bash
CMD ["tail", "-f", "/dev/null"]
