FROM golang:1.26-alpine AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ ./
RUN CGO_ENABLED=0 go build -trimpath -o /backend ./cmd/server
FROM alpine:3.23
RUN apk add --no-cache ca-certificates tzdata && addgroup -g 10001 agent && adduser -D -u 10001 -G agent agent
WORKDIR /app
COPY --from=build /backend ./backend
COPY backend/config.yaml ./config.yaml
COPY deploy/personal-agent/secret-env.sh ./secret-env.sh
USER 10001:10001
ENTRYPOINT ["/bin/sh","/app/secret-env.sh"]
CMD ["./backend"]
