# OpenClaw Bot Chat Backend

本目录构建两个独立应用进程：

- `cmd/server`：用户/Agent 鉴权、资源权限、bootstrap、历史和业务 API；仅发布 Agent 事件。
- `cmd/message-ingest`：订阅 `chat/#`，写入本地持久队列，再由有界工作池落库。无需 API 或 Redis 存活。

Go 版本以 `go.mod` 为准。两者共享 PostgreSQL 的业务模型，API 另用 Redis。
MQTTS Broker 与 Protobuf 授权服务属于独立仓库，部署使用预构建镜像。

## 启动与配置

从 `config.yaml` 读取配置，也支持环境变量。API 与消费者必须使用不同的
`MQTT_USERNAME`、`MQTT_PASSWORD`、`MQTT_CLIENT_ID`。容器配置通过
`INGEST_MQTT_PASSWORD` 为消费者注入独立密码；原生启动时给各进程设置自己的 `MQTT_*`。

```sh
go build -o bin/backend ./cmd/server
go build -o bin/message-ingest ./cmd/message-ingest
# 使用各自的环境分别启动；先完成数据库初始化。
./bin/backend
./bin/message-ingest
```

API 的 `/health/ready` 检查数据库与 Redis。消费者另有默认
`127.0.0.1:8081/health/ready`，检查订阅、数据库和队列，并返回积压、死信和重试计数。
历史查询仍通过 REST，实时消息经 Broker 转发。

[完整消费架构、部署和恢复边界](../docs/MESSAGE_INGEST.md)
· [MQTTS 与权限接入](../docs/MQTTS_ACCESS.md)
· [API 文档](../docs/API.md)
