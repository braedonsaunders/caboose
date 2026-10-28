# Debian 13 with Node 22, caboose-agentd installed by its own install.sh, the desktop MCP
# server, and a stand-in ACP agent behind `npx -y @caboose/stand-in-agent@1.0.0`. Built from
# the repository's guest/ directory by ../check-agent-shell.sh.
FROM node:22-trixie-slim
RUN userdel -r node && useradd -m -u 1000 -s /bin/bash caboose && \
    install -d -o caboose -g caboose /home/caboose/Agents /home/caboose/.local/bin
COPY agentd/caboose-agentd.mjs agentd/package.json agentd/install.sh /tmp/agentd/
RUN /tmp/agentd/install.sh && rm -rf /tmp/agentd
COPY desktop-mcp/caboose-desktop-mcp.mjs /opt/caboose/desktop-mcp.mjs
COPY agentd/test/stand-in-agent.mjs /opt/caboose/agentd/stand-in-agent.mjs
RUN printf '#!/bin/sh\n# The stand-in package runs the stand-in agent; anything else is the real npx.\nif [ "$1" = -y ] && [ "$2" = @caboose/stand-in-agent@1.0.0 ]; then shift 2; exec node /opt/caboose/agentd/stand-in-agent.mjs "$@"; fi\nexec /usr/local/bin/npx "$@"\n' > /home/caboose/.local/bin/npx && \
    chmod 0755 /home/caboose/.local/bin/npx && chown -R caboose:caboose /home/caboose/.local
CMD ["sleep", "infinity"]
