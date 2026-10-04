FROM node:24-bookworm-slim AS build
WORKDIR /app
COPY test/openclaw-bot-chat/package*.json ./
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/proxy_ca; fi; \
    npm ci --no-audit --no-fund
COPY test/openclaw-bot-chat/ ./
RUN npm run build && npm prune --omit=dev --no-audit --no-fund
FROM node:24-bookworm-slim
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    apt-get -o Acquire::https::CaInfo="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" update && \
    apt-get -o Acquire::https::CaInfo="${SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}" install -y --no-install-recommends ca-certificates ripgrep && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=node:node /app /app
COPY --chown=node:node deploy/personal-agent/secret-env.sh /app/secret-env.sh
USER node
ENV OPENCLAW_STATE_DIR=/state OPENCLAW_AGENT_HANDLER=/app/examples/openai-compatible-handler.cjs
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s CMD node -e 'const h=require("/state/health.json");process.exit(h.ready&&Date.now()-h.at<90000?0:1)'
ENTRYPOINT ["/bin/sh","/app/secret-env.sh"]
CMD ["node","dist/index.js"]
