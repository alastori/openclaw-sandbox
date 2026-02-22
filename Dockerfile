FROM node:22-bookworm-slim

# Install dependencies (build tools needed for native modules like @discordjs/opus)
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

# Remove build tools to reduce image size
RUN apt-get purge -y build-essential python3 && apt-get autoremove -y

# Create non-root user workspace
RUN mkdir -p /home/node/.openclaw /home/node/workspace \
    && chown -R node:node /home/node

USER node
WORKDIR /home/node

EXPOSE 18789

# Start the gateway in foreground mode
CMD ["openclaw", "gateway", "run"]
