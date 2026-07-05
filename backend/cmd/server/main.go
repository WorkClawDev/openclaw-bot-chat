package main

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/handler"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/mqtt"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/internal/service"
	"github.com/openclaw-bot-chat/backend/internal/storage"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"github.com/redis/go-redis/v9"
	"github.com/rs/zerolog"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func main() {
	cfg, err := config.Load("config.yaml")
	if err != nil {
		fmt.Printf("failed to load config: %v\n", err)
		os.Exit(1)
	}

	// Setup zerolog
	log := zerolog.New(os.Stdout).With().Timestamp().Logger()
	if cfg.Log.Format != "json" {
		log = zerolog.New(zerolog.ConsoleWriter{Out: os.Stdout, TimeFormat: time.RFC3339}).With().Timestamp().Logger()
	}
	logLevel, _ := zerolog.ParseLevel(cfg.Log.Level)
	log = log.Level(logLevel)
	log.Info().Str("mode", cfg.App.Mode).Msg("starting server")

	if cfg.App.Mode == "release" {
		gin.SetMode(gin.ReleaseMode)
	}
	router := gin.New()
	router.Use(middleware.Recovery(log))
	router.Use(middleware.Logger(log))
	router.Use(middleware.CORS())

	// --- Database ---
	db, err := setupDatabase(cfg, log)
	if err != nil {
		log.Fatal().Err(err).Msg("failed to setup database")
	}

	// --- Redis ---
	rdb := setupRedis(cfg, log)

	// --- JWT Manager ---
	jwtManager := jwt.NewManager(jwt.Config{
		Secret:          cfg.JWT.Secret,
		AccessTokenTTL:  cfg.JWT.AccessTokenTTL,
		RefreshTokenTTL: cfg.JWT.RefreshTokenTTL,
		Issuer:          cfg.JWT.Issuer,
	})

	// --- Repositories ---
	userRepo := repository.NewUserRepository(db)
	botRepo := repository.NewBotRepository(db)
	keyRepo := repository.NewBotKeyRepository(db)
	bindingTokenRepo := repository.NewBotBindingTokenRepository(db)
	msgRepo := repository.NewMessageRepository(db)
	groupRepo := repository.NewGroupRepository(db)
	assetRepo := repository.NewAssetRepository(db)
	auditRepo := repository.NewAuditLogRepository(db)
	taskRepo := repository.NewTaskRepository(db)
	documentRepo := repository.NewDocumentRepository(db)

	// --- Object Storage ---
	objectStorage, err := storage.NewProvider(cfg.Storage)
	if err != nil {
		log.Fatal().Err(err).Msg("failed to setup object storage")
	}

	// --- Services ---
	authService := service.NewAuthService(userRepo, auditRepo, jwtManager)
	var phoneAuthService *service.PhoneAuthService
	if cfg.Auth.Phone.Enabled {
		captchaProvider, err := service.NewCaptchaProvider(cfg.Captcha, cfg.App.Mode)
		if err != nil {
			log.Fatal().Err(err).Msg("failed to setup captcha provider")
		}
		smsProvider, err := service.NewSMSProvider(cfg.SMS, cfg.App.Mode)
		if err != nil {
			log.Fatal().Err(err).Msg("failed to setup sms provider")
		}
		phoneAuthService = service.NewPhoneAuthService(
			userRepo,
			auditRepo,
			jwtManager,
			service.NewRedisPhoneCodeStore(rdb),
			captchaProvider,
			smsProvider,
			cfg.Auth.Phone,
		)
	}
	botService := service.NewBotService(botRepo, keyRepo, bindingTokenRepo, auditRepo)
	assetService := service.NewAssetService(assetRepo, objectStorage, cfg.Storage, cfg.Asset)
	msgService := service.NewMessageService(msgRepo, botRepo, groupRepo, assetRepo, auditRepo, assetService)
	groupService := service.NewGroupService(groupRepo, botRepo, auditRepo)
	taskService := service.NewTaskService(taskRepo, botRepo)
	documentService := service.NewDocumentService(documentRepo)

	// --- MQTT Client ---
	mqttClient := mqtt.NewClient(mqtt.MQTTConfig{
		Broker:         cfg.MQTT.Broker,
		ClientID:       cfg.MQTT.ClientID,
		Username:       cfg.MQTT.Username,
		Password:       cfg.MQTT.Password,
		TopicPrefix:    cfg.MQTT.TopicPrefix,
		QOS:            cfg.MQTT.QOS,
		AutoReconnect:  cfg.MQTT.AutoReconnect,
		ReconnectDelay: cfg.MQTT.ReconnectDelay,
	}, log, msgService)

	if err := mqttClient.Connect(); err != nil {
		log.Warn().Err(err).Msg("MQTT connection failed, continuing without MQTT")
	} else {
		defer mqttClient.Disconnect()
	}

	// --- Handlers ---
	authHandler := handler.NewAuthHandler(authService, phoneAuthService)
	botHandler := handler.NewBotHandler(botService)
	msgHandler := handler.NewMessageHandler(msgService)
	realtimeHandler := handler.NewRealtimeHandler(msgService, cfg.MQTT)
	assetHandler := handler.NewAssetHandler(assetService)
	botRuntimeHandler := handler.NewBotRuntimeHandler(msgService, assetService, cfg.MQTT)
	botRuntimeHandler.SetDocumentService(documentService)
	groupHandler := handler.NewGroupHandler(groupService)
	taskHandler := handler.NewTaskHandler(taskService)
	taskRuntimeHandler := handler.NewTaskRuntimeHandler(taskService)
	documentHandler := handler.NewDocumentHandler(documentService)

	// --- Routes ---
	setupRoutes(router, authHandler, botHandler, msgHandler, realtimeHandler, assetHandler, botRuntimeHandler, groupHandler, taskHandler, taskRuntimeHandler, documentHandler, botService, jwtManager)

	// --- HTTP Server ---
	addr := fmt.Sprintf("%s:%d", cfg.App.Host, cfg.App.Port)
	srv := &http.Server{
		Addr:         addr,
		Handler:      router,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		<-sigCh
		log.Info().Msg("shutting down server...")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Error().Err(err).Msg("server shutdown error")
		}
	}()

	log.Info().Str("addr", addr).Msg("server listening")
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal().Err(err).Msg("server error")
	}
	log.Info().Msg("server stopped")
}

func setupDatabase(cfg *config.Config, log zerolog.Logger) (*gorm.DB, error) {
	dsn := cfg.Database.DSN()
	gormConfig := &gorm.Config{
		Logger: logger.Default.LogMode(logger.Warn),
	}
	db, err := gorm.Open(postgres.Open(dsn), gormConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %w", err)
	}
	sqlDB, err := db.DB()
	if err != nil {
		return nil, fmt.Errorf("failed to get underlying db: %w", err)
	}
	sqlDB.SetMaxOpenConns(cfg.Database.MaxOpenConns)
	sqlDB.SetMaxIdleConns(cfg.Database.MaxIdleConns)
	sqlDB.SetConnMaxLifetime(cfg.Database.ConnMaxLifetimeDuration())

	log.Info().Msg("database connected")

	// Auto-migrate models
	if err := db.AutoMigrate(
		&model.User{},
		&model.Bot{},
		&model.BotKey{},
		&model.BotBindingToken{},
		&model.Message{},
		&model.Asset{},
		&model.Document{},
		&model.Group{},
		&model.GroupMember{},
		&model.BotGroupMember{},
		&model.Task{},
		&model.TaskDependency{},
		&model.TaskEvent{},
		&model.AuditLog{},
	); err != nil {
		return nil, fmt.Errorf("failed to migrate database: %w", err)
	}
	log.Info().Msg("database migrated")

	return db, nil
}

func setupRedis(cfg *config.Config, log zerolog.Logger) *redis.Client {
	rdb := redis.NewClient(&redis.Options{
		Addr:     cfg.Redis.Addr(),
		Password: cfg.Redis.Password,
		DB:       cfg.Redis.DB,
		PoolSize: cfg.Redis.PoolSize,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Warn().Err(err).Msg("Redis connection failed, continuing without Redis")
	} else {
		log.Info().Msg("Redis connected")
	}
	return rdb
}

func setupRoutes(
	r *gin.Engine,
	authHandler *handler.AuthHandler,
	botHandler *handler.BotHandler,
	msgHandler *handler.MessageHandler,
	realtimeHandler *handler.RealtimeHandler,
	assetHandler *handler.AssetHandler,
	botRuntimeHandler *handler.BotRuntimeHandler,
	groupHandler *handler.GroupHandler,
	taskHandler *handler.TaskHandler,
	taskRuntimeHandler *handler.TaskRuntimeHandler,
	documentHandler *handler.DocumentHandler,
	botService *service.BotService,
	jwtManager *jwt.Manager,
) {
	r.GET("/health", func(c *gin.Context) {
		c.JSON(200, gin.H{"status": "ok"})
	})

	api := r.Group("/api/v1")

	// Public auth routes
	auth := api.Group("/auth")
	{
		auth.POST("/register", authHandler.Register)
		auth.POST("/login", authHandler.Login)
		auth.POST("/phone/code", authHandler.RequestPhoneCode)
		auth.POST("/phone/login", authHandler.PhoneLogin)
		auth.POST("/refresh", authHandler.Refresh)
	}

	botRuntime := api.Group("/bot-runtime")
	botRuntime.Use(middleware.BotKeyAuth(botService))
	{
		botRuntime.GET("/bootstrap", botRuntimeHandler.Bootstrap)
		botRuntime.GET("/messages/*conversation_id", botRuntimeHandler.GetConversationMessages)
		botRuntime.POST("/assets/image/import", botRuntimeHandler.ImportImage)
		botRuntime.POST("/assets/audio/import", botRuntimeHandler.ImportAudio)
		if documentsFeatureEnabled() {
			botRuntime.POST("/documents", botRuntimeHandler.CreateDocument)
			botRuntime.PUT("/documents/:id", botRuntimeHandler.UpdateDocument)
		}
		botRuntime.GET("/tasks", taskRuntimeHandler.List)
		botRuntime.GET("/tasks/queue", taskRuntimeHandler.Queue)
		botRuntime.POST("/tasks", taskRuntimeHandler.Create)
		botRuntime.POST("/tasks/:id/claim", taskRuntimeHandler.Claim)
		botRuntime.POST("/tasks/:id/progress", taskRuntimeHandler.Progress)
		botRuntime.POST("/tasks/:id/result", taskRuntimeHandler.Result)
		botRuntime.POST("/tasks/:id/complete", taskRuntimeHandler.Complete)
		botRuntime.POST("/tasks/:id/fail", taskRuntimeHandler.Fail)
	}

	api.GET("/assets/image/:id", assetHandler.RedirectPublicImage)
	api.GET("/assets/audio/:id", assetHandler.RedirectPublicAudio)

	// Protected routes
	protected := api.Group("")
	protected.Use(middleware.JWTAuth(jwtManager))
	{
		protected.POST("/auth/logout", authHandler.Logout)
		protected.GET("/auth/me", authHandler.Me)
		protected.PUT("/auth/me", authHandler.UpdateMe)
		protected.POST("/auth/change-password", authHandler.ChangePassword)

		// Bots
		protected.GET("/bots", botHandler.List)
		protected.POST("/bots", botHandler.Create)
		protected.GET("/bots/:id", botHandler.Get)
		protected.PUT("/bots/:id", botHandler.Update)
		protected.DELETE("/bots/:id", botHandler.Delete)
		protected.POST("/bots/:id/bindings", botHandler.CreateBinding)

		// Bot Keys
		protected.GET("/bots/:id/keys", botHandler.ListKeys)
		protected.POST("/bots/:id/keys", botHandler.CreateKey)
		protected.DELETE("/bots/:id/keys/:key_id", botHandler.RevokeKey)
		protected.GET("/bot-bindings/preview", botHandler.PreviewBinding)
		protected.POST("/bot-bindings/confirm", botHandler.ConfirmBinding)

		// Messages
		protected.GET("/realtime/bootstrap", realtimeHandler.Bootstrap)
		protected.GET("/messages", msgHandler.GetMessages)
		protected.GET("/messages/*conversation_id", msgHandler.GetMessagesByConversation)
		protected.GET("/conversations", msgHandler.GetConversations)
		protected.POST("/assets/image/upload-prepare", assetHandler.PrepareImageUpload)
		protected.POST("/assets/image/complete", assetHandler.CompleteImageUpload)
		protected.POST("/assets/audio/upload-prepare", assetHandler.PrepareAudioUpload)
		protected.POST("/assets/audio/complete", assetHandler.CompleteAudioUpload)

		if documentsFeatureEnabled() {
			// Documents
			protected.GET("/documents", documentHandler.List)
			protected.POST("/documents", documentHandler.Create)
			protected.GET("/documents/:id", documentHandler.Get)
			protected.PUT("/documents/:id", documentHandler.Update)
			protected.DELETE("/documents/:id", documentHandler.Archive)
		}

		// Groups
		protected.GET("/groups", groupHandler.List)
		protected.POST("/groups", groupHandler.Create)
		protected.GET("/groups/:id", groupHandler.Get)
		protected.PUT("/groups/:id", groupHandler.Update)
		protected.DELETE("/groups/:id", groupHandler.Delete)
		protected.POST("/groups/:id/members", groupHandler.AddMember)
		protected.DELETE("/groups/:id/members/:uid", groupHandler.RemoveMember)
		protected.GET("/groups/:id/members", groupHandler.GetMembers)

		// Tasks
		protected.GET("/tasks", taskHandler.List)
		protected.POST("/tasks", taskHandler.Create)
		protected.GET("/tasks/:id", taskHandler.Get)
		protected.PUT("/tasks/:id", taskHandler.Update)
		protected.POST("/tasks/:id/reassign", taskHandler.Reassign)
		protected.POST("/tasks/:id/dispatch", taskHandler.Dispatch)
		protected.POST("/tasks/:id/accept", taskHandler.Accept)
		protected.POST("/tasks/:id/reject", taskHandler.Reject)
		protected.POST("/tasks/:id/retry", taskHandler.Retry)
		protected.POST("/tasks/:id/cancel", taskHandler.Cancel)
		protected.DELETE("/tasks/:id", taskHandler.Delete)
	}

}

func documentsFeatureEnabled() bool {
	raw := strings.ToLower(strings.TrimSpace(os.Getenv("OPENCLAW_DOCUMENTS_ENABLED")))
	return raw != "false" && raw != "0" && raw != "off"
}
