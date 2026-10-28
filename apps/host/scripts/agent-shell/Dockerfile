FROM debian:trixie-slim
RUN useradd -m -u 1000 -s /bin/bash caboose && mkdir -p /home/caboose/Agents && chown caboose /home/caboose/Agents
COPY fake-claude /usr/local/bin/claude
COPY fake-codex /usr/local/bin/codex
CMD ["sleep", "infinity"]
