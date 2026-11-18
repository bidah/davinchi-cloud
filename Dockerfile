# syntax=docker/dockerfile:1
#
# DaVinci Resolve (Studio) on a Daytona GPU sandbox
# --------------------------------------------------
# - Ubuntu 22.04 + the desktop stack Daytona's VNC / Computer Use expects
#   (xvfb, xfce4, x11vnc, novnc) -> desktop is started by `sandbox.computer_use.start()`.
# - NVIDIA driver/CUDA/EGL/OpenCL libs are injected at runtime by Daytona's GPU
#   runtime (NVIDIA_DRIVER_CAPABILITIES=all), nothing driver-related is baked in.
# - VirtualGL (EGL back end) lets Resolve's OpenGL UI render on the GPU even
#   though the X server (Xvfb) has no GPU.
# - Resolve is installed in a throw-away stage so the ~3 GB installer zip never
#   ends up in the final image.
#
# Put the official Linux installer in ./optional/ before building:
#   optional/DaVinci_Resolve_Studio_21.2_Linux.zip   (or the extracted .run)
#
FROM ubuntu:22.04 AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG VIRTUALGL_VERSION=3.1.5

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=all \
    VNC_RESOLUTION=1920x1080

# Desktop/VNC stack required by Daytona Computer Use + Resolve runtime deps
# (Ubuntu equivalents of davincibox's dependency list).
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget unzip file sudo procps less nano git jq pciutils lshw \
      python3 python3-pip python3-venv ffmpeg fonts-dejavu fonts-liberation \
      xvfb xfce4 xfce4-terminal x11vnc novnc websockify dbus-x11 x11-utils xdotool \
      libx11-6 libxrandr2 libxext6 libxrender1 libxfixes3 libxss1 libxtst6 libxi6 \
      libasound2 libpulse0 libapr1 libaprutil1 libdbus-1-3 libnss3 libmtdev1 \
      libice6 libsm6 librsvg2-2 libxcursor1 libxinerama1 libxkbfile1 libxxf86vm1 \
      libxkbcommon0 libxkbcommon-x11-0 libglib2.0-0 libgdk-pixbuf-2.0-0 libfuse2 \
      libxcb1 libxcb-cursor0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 \
      libxcb-render-util0 libxcb-util1 libxcb-xinerama0 libxcb-xkb1 libxcb-randr0 \
      libxcb-shape0 libxcb-xfixes0 libxcb-sync1 libxcb-composite0 libxcb-damage0 \
      libgl1 libglx0 libegl1 libgles2 libglu1-mesa libglvnd0 mesa-utils libgl1-mesa-dri \
      ocl-icd-libopencl1 clinfo patchelf \
 && rm -rf /var/lib/apt/lists/*

# VirtualGL (GPU-accelerated OpenGL for apps on a virtual X display)
RUN curl -fsSL -o /tmp/vgl.deb \
      "https://github.com/VirtualGL/virtualgl/releases/download/${VIRTUALGL_VERSION}/virtualgl_${VIRTUALGL_VERSION}_amd64.deb" \
 && apt-get update && apt-get install -y --no-install-recommends /tmp/vgl.deb \
 && rm -rf /tmp/vgl.deb /var/lib/apt/lists/*

# The NVIDIA runtime mounts libnvidia-opencl but not always the ICD file.
RUN mkdir -p /etc/OpenCL/vendors && echo "libnvidia-opencl.so.1" > /etc/OpenCL/vendors/nvidia.icd

# --------------------------------------------------------------------------
FROM base AS installer
COPY optional/ /tmp/installer/
COPY scripts/install-davinci-resolve.sh /usr/local/bin/install-davinci-resolve.sh
RUN chmod +x /usr/local/bin/install-davinci-resolve.sh \
 && /usr/local/bin/install-davinci-resolve.sh /tmp/installer

# --------------------------------------------------------------------------
FROM base

COPY --from=installer /opt/resolve /opt/resolve
COPY --from=installer /var/BlackmagicDesign /var/BlackmagicDesign

COPY scripts/ /opt/scripts/
RUN chmod +x /opt/scripts/*.sh

# Non-root user. Daytona's GPU snapshots use `daytona` (uid 1001).
ARG USERNAME=daytona
ARG USER_UID=1001
RUN useradd -m -u ${USER_UID} -s /bin/bash ${USERNAME} \
 && usermod -aG video,audio ${USERNAME} \
 && (getent group render >/dev/null || groupadd -r render) && usermod -aG render ${USERNAME} \
 && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
 && chmod 0440 /etc/sudoers.d/${USERNAME} \
 # Resolve writes configs/logs/licence (Studio activation lives in /opt/resolve/.license)
 && mkdir -p /opt/resolve/.license /opt/resolve/configs /opt/resolve/logs /opt/resolve/easyDCP \
             /opt/resolve/Fairlight /opt/resolve/LUT /opt/resolve/Extras /opt/resolve/DolbyVision \
 && chown -R ${USERNAME}:${USERNAME} /opt/resolve/.license /opt/resolve/configs /opt/resolve/logs \
             /opt/resolve/easyDCP /opt/resolve/Fairlight /opt/resolve/LUT /opt/resolve/Extras \
             /opt/resolve/DolbyVision /var/BlackmagicDesign \
 # Desktop launcher (XFCE desktop + app menu)
 && install -d /home/${USERNAME}/Desktop /home/${USERNAME}/media \
 && cp /opt/scripts/davinci-resolve.desktop /usr/share/applications/davinci-resolve.desktop \
 && cp /opt/scripts/davinci-resolve.desktop /home/${USERNAME}/Desktop/davinci-resolve.desktop \
 && chmod +x /home/${USERNAME}/Desktop/davinci-resolve.desktop \
 && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}

# Optional: davinci-resolve MCP server for agent control (non-fatal).
ARG INSTALL_MCP=1
ARG MCP_VERSION=5.3.4
RUN if [ "$INSTALL_MCP" = "1" ]; then MCP_VERSION="${MCP_VERSION}" /opt/scripts/install-resolve-mcp.sh || echo "MCP install skipped"; fi

ENV RESOLVE_SCRIPT_API=/opt/resolve/Developer/Scripting \
    RESOLVE_SCRIPT_LIB=/opt/resolve/libs/Fusion/fusionscript.so \
    PYTHONPATH=/opt/resolve/Developer/Scripting/Modules \
    PATH=/opt/resolve/bin:/opt/VirtualGL/bin:/opt/scripts:${PATH}

USER ${USERNAME}
WORKDIR /home/${USERNAME}
