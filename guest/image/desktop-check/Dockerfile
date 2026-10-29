FROM debian:13-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb xauth xdotool dbus-x11 desktop-file-utils libglib2.0-bin \
    python3-gi gir1.2-gtk-3.0 procps && \
    useradd -m -u 1000 -s /bin/bash caboose
COPY desktop-apps.sh desktop-apps.tsv /installer/
RUN bash /installer/desktop-apps.sh && bash /installer/desktop-apps.sh
COPY desktop-check/run.sh /check.sh
CMD ["bash", "/check.sh"]
