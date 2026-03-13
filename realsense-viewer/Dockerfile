# =============================================================================
# Intel RealSense Viewer 2.56.5 — Jetson Orin Nano (ARM64)
# FEJLESZTÉSI / TESZTELÉSI ESZKÖZ — nem része az alap production stacknek
#
# RSUSB backend + OpenGL/GLFW GUI (X11 forwarding)
#
# Indítás: bash scripts/viewer.sh
# Kézi build: docker compose -f docker-compose.dev.yml build realsense-viewer
#
# Várható build idő: ~30-45 perc (ARM64, graphical deps + full GUI build)
# =============================================================================

# ─── Stage 1: Builder ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS builder

ARG LIBREALSENSE_VERSION=v2.56.5

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Budapest

RUN apt-get update && apt-get install -y --no-install-recommends \
    # Fordítói lánc
    build-essential \
    cmake \
    git \
    pkg-config \
    # SSL / hálózat
    ca-certificates \
    curl \
    # USB — RSUSB backend
    libusb-1.0-0-dev \
    libudev-dev \
    libssl-dev \
    # OpenGL + GLFW — realsense-viewer GUI dep
    libglfw3-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    # GTK3 — file dialog, tooltips
    libgtk-3-dev \
    # X11 build dep
    libx11-dev \
    libxrandr-dev \
    libxinerama-dev \
    libxcursor-dev \
    libxi-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone \
    --depth 1 \
    --branch ${LIBREALSENSE_VERSION} \
    https://github.com/realsenseai/librealsense.git \
    /opt/librealsense

# BUILD_GRAPHICAL_EXAMPLES=ON → realsense-viewer és OpenGL példák is lefordulnak
RUN cmake \
    -S /opt/librealsense \
    -B /opt/librealsense/build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS_RELEASE="-O3 -DNDEBUG -march=native -fno-plt" \
    -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -march=native -fno-plt" \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON \
    -DFORCE_RSUSB_BACKEND=ON \
    -DBUILD_EXAMPLES=ON \
    -DBUILD_GRAPHICAL_EXAMPLES=ON \
    -DBUILD_TOOLS=ON \
    -DBUILD_PYTHON_BINDINGS=OFF \
    -DBUILD_UNITY_BINDINGS=OFF \
    -DBUILD_WITH_CUDA=OFF \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_INSTALL_PREFIX=/opt/rs-install

RUN cmake --build /opt/librealsense/build \
    --config Release \
    --parallel $(nproc) \
    && cmake --install /opt/librealsense/build


# ─── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM ubuntu:22.04 AS runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Europe/Budapest

RUN apt-get update && apt-get install -y --no-install-recommends \
    # USB runtime
    libusb-1.0-0 \
    libudev1 \
    libssl3 \
    # OpenGL + GLFW runtime
    libglfw3 \
    libgl1-mesa-glx \
    libglu1-mesa \
    # GTK3 runtime
    libgtk-3-0 \
    # X11 runtime
    libx11-6 \
    libxrandr2 \
    libxinerama1 \
    libxcursor1 \
    libxi6 \
    # Egyéb GUI dep
    libdbus-1-3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/rs-install /usr/local
# udev rules a konténerben — viewer warning elnyomásához (builder-ben van curl)
COPY --from=builder /opt/librealsense/config/99-realsense-libusb.rules /etc/udev/rules.d/99-realsense-libusb.rules
RUN ldconfig

ENV NVIDIA_VISIBLE_DEVICES=all
ENV NVIDIA_DRIVER_CAPABILITIES=all,graphics,display,utility

CMD ["realsense-viewer"]
