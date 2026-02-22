FROM node:22-bookworm-slim

# Install build tools for native modules (e.g. @discordjs/opus)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    python3 \
    build-essential \
    libopus-dev \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Remove build tools but keep python3 for agent tasks
RUN apt-get purge -y build-essential && apt-get autoremove -y \
    && apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user workspace
RUN mkdir -p /home/node/.openclaw /home/node/workspace \
    && chown -R node:node /home/node

USER node
WORKDIR /home/node

EXPOSE 18789

# Start the gateway in foreground mode
CMD ["openclaw", "gateway", "run"]
