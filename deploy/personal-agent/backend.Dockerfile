FROM golang:1.26-alpine AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -o /backend ./cmd/server && CGO_ENABLED=0 go build -trimpath -o /admin-user ./cmd/admin-user
FROM alpine:3.23
RUN --mount=type=secret,id=proxy_ca \
    if [ -f /run/secrets/proxy_ca ]; then export SSL_CERT_FILE=/run/secrets/proxy_ca; fi; \
    apk add --no-cache ca-certificates tzdata && addgroup -g 10001 agent && adduser -D -u 10001 -G agent agent
WORKDIR /app
COPY --from=build /backend ./backend
COPY --from=build /admin-user ./admin-user
COPY --chmod=0444 backend/config.yaml ./config.yaml
COPY --chmod=0444 deploy/personal-agent/secret-env.sh ./secret-env.sh
USER 10001:10001
ENTRYPOINT ["/bin/sh","/app/secret-env.sh"]
CMD ["./backend"]
