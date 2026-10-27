FROM debian:trixie-slim
RUN apt-get update -qq && apt-get install -y --no-install-recommends ca-certificates curl
RUN curl -fsSL https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc && \
    curl -fsSL https://raw.githubusercontent.com/Xpra-org/xpra/v6.5.5/packaging/repos/trixie/xpra.sources -o /etc/apt/sources.list.d/xpra.sources
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    xpra=6.5.5-r0-1 xpra-client=6.5.5-r0-1 xpra-client-gtk3=6.5.5-r0-1 \
    xpra-common=6.5.5-r0-1 xpra-server=6.5.5-r0-1 xpra-x11=6.5.5-r0-1 \
    xpra-codecs=6.5.5-r0-1 xpra-codecs-extras=6.5.5-r0-1 \
    libx264-164 xterm x11-apps xvfb python3-websockets xclip xauth xdotool && apt-get clean
RUN apt-get update -qq && apt-get install -y --no-install-recommends x11-utils && apt-get clean
