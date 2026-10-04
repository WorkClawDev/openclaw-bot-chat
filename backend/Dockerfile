# Build stage
FROM golang:1.26-alpine AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod go.sum ./
RUN go env -w GOPROXY=https://mirrors.aliyun.com/goproxy/,direct
RUN go mod download

# Copy source code
COPY . .

# Build
RUN CGO_ENABLED=0 GOOS=linux go build -o backend ./cmd/server && CGO_ENABLED=0 GOOS=linux go build -o admin-user ./cmd/admin-user && CGO_ENABLED=0 GOOS=linux go build -o message-ingest ./cmd/message-ingest

# Runtime stage
FROM alpine:3.19 AS runtime

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache ca-certificates tzdata

COPY --from=builder /app/config.yaml .

FROM runtime AS message-ingest
COPY --from=builder /app/message-ingest .
RUN mkdir -p /data && chmod 700 /data
ENV INGEST_LISTEN=0.0.0.0:8081 INGEST_SPOOL_PATH=/data/messages.db
EXPOSE 8081
CMD ["./message-ingest"]

FROM runtime AS backend
COPY --from=builder /app/backend .
COPY --from=builder /app/admin-user .
EXPOSE 8080
CMD ["./backend"]
