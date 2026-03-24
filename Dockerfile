FROM node:22-bookworm-slim

ARG OPENCLAW_VERSION=latest
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

# Remove build tools but keep python3 and cron for agent tasks
RUN apt-get purge -y build-essential && apt-get autoremove -y \
    && apt-get update && apt-get install -y --no-install-recommends python3 cron \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user workspace
RUN mkdir -p /home/node/.openclaw /home/node/workspace \
    && chmod 700 /home/node/.openclaw /home/node/workspace \
    && chown -R node:node /home/node

USER node
WORKDIR /home/node

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:${OPENCLAW_PORT:-18789}/ -o /dev/null || exit 1

# Start the gateway in foreground mode
CMD ["openclaw", "gateway", "run"]
