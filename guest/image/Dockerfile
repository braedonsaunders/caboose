FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends debootstrap eatmydata util-linux fdisk e2fsprogs ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY image/build-inside.sh image/configure-guest.sh image/apps.sh image/caboose-xpra.service image/caboose-xpra-agent.service /builder/
COPY desktop-mcp /builder/desktop-mcp
ENTRYPOINT ["/builder/build-inside.sh"]
