FROM node:22-bookworm-slim

# Pinned: 2026.4.6+ installs plugin node_modules at CLI/gateway load time,
# which fails on our read_only rootfs. See ROADMAP.md "Watching upstream".
ARG OPENCLAW_VERSION=2026.4.5
ARG INSTALL_GEMINI_CLI=true

# Install build tools for native modules (e.g. @discordjs/opus)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    python3 \
    build-essential \
    libopus-dev \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally (and optionally Gemini CLI for OAuth)
RUN npm install -g openclaw@${OPENCLAW_VERSION} \
    && if [ "$INSTALL_GEMINI_CLI" = "true" ]; then npm install -g @google/gemini-cli; fi

# Remove build tools; keep only runtime deps (python3 for extensions, curl for healthcheck)
# Remove cron package (OpenClaw uses its own scheduler, system cron is not started)
RUN apt-get purge -y build-essential && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Harden: strip SUID/SGID bits from all binaries
RUN find / -type f \( -perm -4000 -o -perm -2000 \) -exec chmod a-s {} + 2>/dev/null || true

# Harden: disable root shell login
RUN sed -i 's|root:x:0:0:root:/root:/bin/bash|root:x:0:0:root:/root:/sbin/nologin|' /etc/passwd

# Harden: remove world-writable dirs (except /tmp which is tmpfs)
RUN chmod 1770 /var/tmp && chmod 1770 /run/lock

# Create non-root user workspace
RUN mkdir -p /home/node/.openclaw /home/node/workspace /home/node/skills \
    && chmod 700 /home/node/.openclaw /home/node/workspace \
    && chown -R node:node /home/node

USER node
WORKDIR /home/node

# Install ClawSec security skill suite as the runtime user
RUN npx clawhub@latest install clawsec-suite --no-input

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:${OPENCLAW_PORT:-18789}/ -o /dev/null || exit 1

# Start the gateway with restrictive umask (logs, sessions created as 600)
CMD ["sh", "-c", "umask 0077 && exec openclaw gateway run"]
