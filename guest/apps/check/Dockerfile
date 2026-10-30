# Test bed for the caboose-app runtime: Debian 13 with Xvfb, a session bus, PyGObject,
# WebKitGTK 4.1, GStreamer's good plugins and curl, the packages a Caboose computer has.
# Native architecture: builds on amd64 and arm64. Built by ../check-runtime.sh.
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb xauth dbus dbus-x11 python3 python3-gi gir1.2-gtk-3.0 gir1.2-webkit2-4.1 \
      librsvg2-common libgl1-mesa-dri fonts-dejavu-core procps curl \
      gstreamer1.0-plugins-good && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 -s /bin/bash caboose
CMD ["sleep", "infinity"]
