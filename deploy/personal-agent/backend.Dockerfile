FROM golang:1.26-alpine AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -o /backend ./cmd/server && CGO_ENABLED=0 go build -trimpath -o /admin-user ./cmd/admin-user && CGO_ENABLED=0 go build -trimpath -o /message-ingest ./cmd/message-ingest
FROM alpine:3.23 AS runtime
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    apk add --no-cache ca-certificates tzdata && addgroup -g 10001 agent && adduser -D -u 10001 -G agent agent
WORKDIR /app
COPY --chmod=0444 backend/config.yaml ./config.yaml
COPY --chmod=0444 deploy/personal-agent/secret-env.sh ./secret-env.sh
RUN mkdir -p /data && chown 10001:10001 /data && chmod 700 /data
USER 10001:10001
ENTRYPOINT ["/bin/sh","/app/secret-env.sh"]

FROM runtime AS message-ingest
COPY --from=build /message-ingest ./message-ingest
ENV INGEST_LISTEN=0.0.0.0:8081 INGEST_SPOOL_PATH=/data/messages.db
EXPOSE 8081
CMD ["./message-ingest"]

FROM runtime AS backend
COPY --from=build /backend ./backend
COPY --from=build /admin-user ./admin-user
CMD ["./backend"]
