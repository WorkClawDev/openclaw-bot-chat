// message-ingest is the independently deployed MQTT -> durable spool ->
// PostgreSQL consumer. Initial schema provisioning remains the API's migration
// responsibility; an unavailable/uninitialized database only delays draining.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/openclaw-bot-chat/backend/internal/brokerrpc"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/ingest"
	"github.com/openclaw-bot-chat/backend/internal/mqtt"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"github.com/openclaw-bot-chat/backend/internal/storage"
	"github.com/rs/zerolog"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func main() {
	log := zerolog.New(os.Stdout).With().Timestamp().Str("service", "message-ingest").Logger()
	if err := run(log); err != nil {
		log.Error().Err(err).Msg("message ingestion stopped")
		os.Exit(1)
	}
}
func run(log zerolog.Logger) error {
	exportDead := flag.String("export-dead", "", "export dead letters to a new private JSONL file; stop the consumer first")
	replayDead := flag.Bool("replay-dead", false, "requeue dead letters after fixing their cause; stop the consumer first")
	purgeDead := flag.Bool("purge-dead", false, "remove dead letters after -export-dead succeeds")
	flag.Parse()
	if *purgeDead && (*exportDead == "" || *replayDead) {
		return errors.New("purge requires export and cannot be combined with replay")
	}
	cfg, err := config.Load("config.yaml")
	if err != nil {
		return err
	}
	if level, err := zerolog.ParseLevel(cfg.Log.Level); err == nil {
		log = log.Level(level)
	}
	spool, err := ingest.Open(cfg.Ingest.SpoolPath, ingest.Limits{MaxBytes: cfg.Ingest.MaxBytes, MaxMessages: cfg.Ingest.MaxMessages, MaxPayloadBytes: cfg.Ingest.MaxPayloadBytes})
	if err != nil {
		return err
	}
	defer spool.Close()
	if *exportDead != "" {
		file, err := os.OpenFile(*exportDead, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return err
		}
		err = spool.ExportDead(file)
		if err == nil {
			err = file.Sync()
		}
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		directory, err := os.Open(filepath.Dir(*exportDead))
		if err != nil {
			return err
		}
		err = directory.Sync()
		_ = directory.Close()
		if err != nil {
			return err
		}
	}
	if *replayDead || *purgeDead {
		return spool.ResolveDead(*replayDead)
	}
	if *exportDead != "" {
		return nil
	}
	// Open lazily: broker intake and durable buffering survive a DB outage.
	db, err := gorm.Open(postgres.Open(cfg.Database.DSN()), &gorm.Config{DisableAutomaticPing: true, Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		return err
	}
	raw, err := db.DB()
	if err != nil {
		return err
	}
	defer raw.Close()
	raw.SetMaxOpenConns(cfg.Database.MaxOpenConns)
	raw.SetMaxIdleConns(cfg.Database.MaxIdleConns)
	raw.SetConnMaxLifetime(cfg.Database.ConnMaxLifetimeDuration())
	assets := repository.NewAssetRepository(db)
	provider, err := storage.NewProvider(cfg.Storage)
	if err != nil {
		return err
	}
	// Preserve existing attachment resolution and legacy remote asset imports.
	messages := service.NewMessageService(repository.NewMessageRepository(db), repository.NewBotRepository(db), repository.NewGroupRepository(db), assets, repository.NewAuditLogRepository(db), service.NewAssetService(assets, provider, cfg.Storage, cfg.Asset))
	consumer, err := ingest.NewConsumer(spool, cfg.Ingest.Workers, func(ctx context.Context, record ingest.Record) error {
		return messages.HandleQueuedMessage(ctx, record.Topic, record.Payload, record.ID, record.ReceivedAt)
	}, func(err error) bool { var invalid *service.PermanentMessageError; return errors.As(err, &invalid) }, log)
	if err != nil {
		return err
	}
	lease, err := brokerrpc.NewSubscriberLease(cfg.BrokerSecurity, cfg.MQTT)
	if err != nil {
		return err
	}
	defer lease.Close()
	client := mqtt.NewClient(mqtt.MQTTConfig{
		Broker: cfg.MQTT.Broker, ClientID: cfg.MQTT.ClientID, Username: cfg.MQTT.Username, Password: cfg.MQTT.Password,
		TopicPrefix: cfg.MQTT.TopicPrefix, QOS: cfg.MQTT.QOS, ReconnectDelay: cfg.MQTT.ReconnectDelay,
		TLSCAFile: cfg.MQTT.TLSCAFile, TLSCertFile: cfg.MQTT.TLSCertFile, TLSKeyFile: cfg.MQTT.TLSKeyFile, TLSServerName: cfg.MQTT.TLSServerName,
	}, log, consumer)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	var wg sync.WaitGroup
	start := func(fn func()) { wg.Add(1); go func() { defer wg.Done(); fn() }() }
	start(func() {
		lease.Run(ctx, func(err error) { log.Warn().Err(err).Msg("subscriber policy renewal failed") })
	})
	start(func() { consumer.Run(ctx) })
	start(func() { client.Run(ctx) })
	defer func() { cancel(); wg.Wait(); client.Disconnect() }()
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"status":"alive"}`))
	})
	mux.HandleFunc("/health/ready", func(w http.ResponseWriter, r *http.Request) {
		check, done := context.WithTimeout(r.Context(), 2*time.Second)
		defer done()
		stats, spoolErr := spool.Stats()
		// to_regclass also catches an unprovisioned schema without running DDL.
		var schemaReady bool
		dbErr := raw.QueryRowContext(check, "SELECT to_regclass('messages') IS NOT NULL AND to_regclass('assets') IS NOT NULL AND to_regclass('bot_group_members') IS NOT NULL").Scan(&schemaReady)
		w.Header().Set("Content-Type", "application/json")
		state := "ready"
		if spoolErr != nil || dbErr != nil || !schemaReady || !client.IsConnected() || !spool.HasCapacity(stats) || consumer.IntakeFailed.Load() {
			state = "unavailable"
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"status": state, "queue": stats, "processed": consumer.Processed.Load(), "retries": consumer.Retries.Load()})
	})
	server := &http.Server{Addr: cfg.Ingest.Listen, Handler: mux, ReadHeaderTimeout: 3 * time.Second, WriteTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second}
	start(func() {
		<-ctx.Done()
		shutdown, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		_ = server.Shutdown(shutdown)
	})
	log.Info().Int("workers", cfg.Ingest.Workers).Str("listen", cfg.Ingest.Listen).Msg("independent message ingestion starting")
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return fmt.Errorf("ingest health server: %w", err)
	}
	return nil
}
