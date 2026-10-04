FROM node:24-bookworm-slim AS build
WORKDIR /app
COPY test/openclaw-bot-chat/package*.json ./
RUN npm ci --no-audit --no-fund
COPY test/openclaw-bot-chat/ ./
RUN npm run build && npm prune --omit=dev
FROM node:24-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ripgrep && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=node:node /app /app
COPY deploy/personal-agent/secret-env.sh /app/secret-env.sh
USER node
ENV OPENCLAW_STATE_DIR=/state OPENCLAW_AGENT_HANDLER=/app/examples/openai-compatible-handler.cjs
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s CMD node -e 'const h=require("/state/health.json");process.exit(h.ready&&Date.now()-h.at<90000?0:1)'
ENTRYPOINT ["/bin/sh","/app/secret-env.sh"]
CMD ["node","dist/index.js"]
