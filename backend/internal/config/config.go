package config

import (
	"fmt"
	"strings"
	"time"

	"github.com/spf13/viper"
)

// Config holds all configuration for the application
type Config struct {
	App      AppConfig
	Database DatabaseConfig
	Redis    RedisConfig
	MQTT     MQTTConfig
	JWT      JWTConfig
	Auth     AuthConfig
	SMS      SMSConfig
	Captcha  CaptchaConfig
	Storage  StorageConfig
	Asset    AssetConfig
	Log      LogConfig
}

// AppConfig holds application-level settings
type AppConfig struct {
	Host string
	Port int
	Mode string // debug, release, test
}

// DatabaseConfig holds PostgreSQL connection settings
type DatabaseConfig struct {
	Host            string
	Port            int
	User            string
	Password        string
	DBName          string
	SSLMode         string
	MaxOpenConns    int
	MaxIdleConns    int
	ConnMaxLifetime int // seconds
}

// RedisConfig holds Redis connection settings
type RedisConfig struct {
	Host     string
	Port     int
	Password string
	DB       int
	PoolSize int
}

// MQTTConfig holds MQTT broker settings
type MQTTConfig struct {
	Broker         string `mapstructure:"broker"`
	ClientID       string `mapstructure:"client_id"`
	Username       string `mapstructure:"username"`
	Password       string `mapstructure:"password"`
	TopicPrefix    string `mapstructure:"topic_prefix"`
	QOS            byte   `mapstructure:"qos"`
	AutoReconnect  bool   `mapstructure:"auto_reconnect"`
	ReconnectDelay int    `mapstructure:"reconnect_delay"`
	TCPPublicURL   string `mapstructure:"tcp_public_url"`
	WSPublicURL    string `mapstructure:"ws_public_url"`
}

type BrokerClientConfig struct {
	TCPPublicURL string `json:"tcp_url"`
	WSPublicURL  string `json:"ws_url"`
	Username     string `json:"username"`
	Password     string `json:"password"`
	QOS          int    `json:"qos"`
}

// JWTConfig holds JWT settings
type JWTConfig struct {
	Secret          string
	AccessTokenTTL  int // seconds
	RefreshTokenTTL int // seconds
	Issuer          string
}

type AuthConfig struct {
	Phone PhoneAuthConfig `mapstructure:"phone"`
}

type PhoneAuthConfig struct {
	Enabled             bool     `mapstructure:"enabled"`
	AllowedCountryCodes []string `mapstructure:"allowed_country_codes"`
	CodeTTLSeconds      int      `mapstructure:"code_ttl_seconds"`
	SendCooldownSeconds int      `mapstructure:"send_cooldown_seconds"`
	PhoneHourlyLimit    int      `mapstructure:"phone_hourly_limit"`
	PhoneDailyLimit     int      `mapstructure:"phone_daily_limit"`
	IPHourlyLimit       int      `mapstructure:"ip_hourly_limit"`
	MaxVerifyAttempts   int      `mapstructure:"max_verify_attempts"`
	CodePepper          string   `mapstructure:"code_pepper"`
	MockCode            string   `mapstructure:"mock_code"`
}

type SMSConfig struct {
	Provider string          `mapstructure:"provider"`
	Aliyun   AliyunSMSConfig `mapstructure:"aliyun"`
}

type AliyunSMSConfig struct {
	AccessKeyID     string `mapstructure:"access_key_id"`
	AccessKeySecret string `mapstructure:"access_key_secret"`
	SignName        string `mapstructure:"sign_name"`
	TemplateCode    string `mapstructure:"template_code"`
	Endpoint        string `mapstructure:"endpoint"`
}

type CaptchaConfig struct {
	Provider  string                 `mapstructure:"provider"`
	Turnstile TurnstileCaptchaConfig `mapstructure:"turnstile"`
}

type TurnstileCaptchaConfig struct {
	SecretKey string `mapstructure:"secret_key"`
	Endpoint  string `mapstructure:"endpoint"`
}

type StorageConfig struct {
	Provider       string           `mapstructure:"provider"`
	Bucket         string           `mapstructure:"bucket"`
	Region         string           `mapstructure:"region"`
	Endpoint       string           `mapstructure:"endpoint"`
	PublicBaseURL  string           `mapstructure:"public_base_url"`
	PrivateRead    bool             `mapstructure:"private_read"`
	UploadURLTTL   int              `mapstructure:"upload_url_ttl"`
	DownloadURLTTL int              `mapstructure:"download_url_ttl"`
	KeyPrefix      string           `mapstructure:"key_prefix"`
	COS            COSStorageConfig `mapstructure:"cos"`
	OSS            OSSStorageConfig `mapstructure:"oss"`
	S3             S3StorageConfig  `mapstructure:"s3"`
}

type COSStorageConfig struct {
	SecretID     string `mapstructure:"secret_id"`
	SecretKey    string `mapstructure:"secret_key"`
	SessionToken string `mapstructure:"session_token"`
}

type OSSStorageConfig struct {
	AccessKeyID     string `mapstructure:"access_key_id"`
	AccessKeySecret string `mapstructure:"access_key_secret"`
	SecurityToken   string `mapstructure:"security_token"`
}

type S3StorageConfig struct {
	Endpoint       string `mapstructure:"endpoint"`
	PublicEndpoint string `mapstructure:"public_endpoint"`
	Region         string `mapstructure:"region"`
	Bucket         string `mapstructure:"bucket"`
	AccessKey      string `mapstructure:"access_key"`
	SecretKey      string `mapstructure:"secret_key"`
	SSL            bool   `mapstructure:"ssl"`
}

type AssetConfig struct {
	MaxImageSizeMB int `mapstructure:"max_image_size_mb"`
	MaxAudioSizeMB int `mapstructure:"max_audio_size_mb"`
}

// LogConfig holds logging settings
type LogConfig struct {
	Level  string // debug, info, warn, error
	Format string // json, console
}

// DSN returns the PostgreSQL connection string
func (d *DatabaseConfig) DSN() string {
	return fmt.Sprintf(
		"host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
		d.Host, d.Port, d.User, d.Password, d.DBName, d.SSLMode,
	)
}

// Addr returns the Redis address
func (r *RedisConfig) Addr() string {
	return fmt.Sprintf("%s:%d", r.Host, r.Port)
}

// Load reads configuration from config.yaml and environment variables
func Load(configPath string) (*Config, error) {
	v := viper.New()
	v.SetConfigFile(configPath)
	v.SetConfigType("yaml")

	// Allow environment variable overrides
	v.AutomaticEnv()
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	v.SetDefault("auth.phone.enabled", true)
	v.SetDefault("auth.phone.allowed_country_codes", []string{"86"})
	v.SetDefault("auth.phone.code_ttl_seconds", 300)
	v.SetDefault("auth.phone.send_cooldown_seconds", 60)
	v.SetDefault("auth.phone.phone_hourly_limit", 5)
	v.SetDefault("auth.phone.phone_daily_limit", 10)
	v.SetDefault("auth.phone.ip_hourly_limit", 30)
	v.SetDefault("auth.phone.max_verify_attempts", 5)
	v.SetDefault("sms.provider", "mock")
	v.SetDefault("sms.aliyun.endpoint", "https://dysmsapi.aliyuncs.com/")
	v.SetDefault("captcha.provider", "mock")
	v.SetDefault("captcha.turnstile.endpoint", "https://challenges.cloudflare.com/turnstile/v0/siteverify")
	bindEnvKeys(v,
		"app.host",
		"app.port",
		"app.mode",
		"database.host",
		"database.port",
		"database.user",
		"database.password",
		"database.dbname",
		"database.sslmode",
		"database.max_open_conns",
		"database.max_idle_conns",
		"database.conn_max_lifetime",
		"redis.host",
		"redis.port",
		"redis.password",
		"redis.db",
		"redis.pool_size",
		"mqtt.broker",
		"mqtt.client_id",
		"mqtt.username",
		"mqtt.password",
		"mqtt.topic_prefix",
		"mqtt.qos",
		"mqtt.auto_reconnect",
		"mqtt.reconnect_delay",
		"mqtt.tcp_public_url",
		"mqtt.ws_public_url",
		"jwt.secret",
		"jwt.access_token_ttl",
		"jwt.refresh_token_ttl",
		"jwt.issuer",
		"auth.phone.enabled",
		"auth.phone.allowed_country_codes",
		"auth.phone.code_ttl_seconds",
		"auth.phone.send_cooldown_seconds",
		"auth.phone.phone_hourly_limit",
		"auth.phone.phone_daily_limit",
		"auth.phone.ip_hourly_limit",
		"auth.phone.max_verify_attempts",
		"auth.phone.code_pepper",
		"auth.phone.mock_code",
		"sms.provider",
		"sms.aliyun.access_key_id",
		"sms.aliyun.access_key_secret",
		"sms.aliyun.sign_name",
		"sms.aliyun.template_code",
		"sms.aliyun.endpoint",
		"captcha.provider",
		"captcha.turnstile.secret_key",
		"captcha.turnstile.endpoint",
		"storage.provider",
		"storage.bucket",
		"storage.region",
		"storage.endpoint",
		"storage.public_base_url",
		"storage.private_read",
		"storage.upload_url_ttl",
		"storage.download_url_ttl",
		"storage.key_prefix",
		"storage.cos.secret_id",
		"storage.cos.secret_key",
		"storage.cos.session_token",
		"storage.oss.access_key_id",
		"storage.oss.access_key_secret",
		"storage.oss.security_token",
		"storage.s3.endpoint",
		"storage.s3.public_endpoint",
		"storage.s3.region",
		"storage.s3.bucket",
		"storage.s3.access_key",
		"storage.s3.secret_key",
		"storage.s3.ssl",
		"asset.max_image_size_mb",
		"asset.max_audio_size_mb",
		"log.level",
		"log.format",
	)

	if err := v.ReadInConfig(); err != nil {
		return nil, fmt.Errorf("failed to read config file: %w", err)
	}

	var cfg Config
	if err := v.Unmarshal(&cfg); err != nil {
		return nil, fmt.Errorf("failed to unmarshal config: %w", err)
	}

	// Set defaults
	if cfg.App.Port == 0 {
		cfg.App.Port = 8080
	}
	if cfg.App.Mode == "" {
		cfg.App.Mode = "debug"
	}
	if cfg.Database.MaxOpenConns == 0 {
		cfg.Database.MaxOpenConns = 25
	}
	if cfg.Database.MaxIdleConns == 0 {
		cfg.Database.MaxIdleConns = 5
	}
	if cfg.Database.ConnMaxLifetime == 0 {
		cfg.Database.ConnMaxLifetime = 300
	}
	if cfg.Redis.PoolSize == 0 {
		cfg.Redis.PoolSize = 10
	}
	if cfg.MQTT.TopicPrefix == "" {
		cfg.MQTT.TopicPrefix = "chat"
	}
	if cfg.MQTT.QOS == 0 {
		cfg.MQTT.QOS = 1
	}
	if cfg.MQTT.TCPPublicURL == "" {
		cfg.MQTT.TCPPublicURL = "mqtt://127.0.0.1:1883"
	}
	if cfg.MQTT.WSPublicURL == "" {
		cfg.MQTT.WSPublicURL = "ws://127.0.0.1:8083/mqtt"
	}
	if cfg.JWT.AccessTokenTTL == 0 {
		cfg.JWT.AccessTokenTTL = 7200
	}
	if cfg.JWT.RefreshTokenTTL == 0 {
		cfg.JWT.RefreshTokenTTL = 604800
	}
	if cfg.Auth.Phone.CodeTTLSeconds == 0 {
		cfg.Auth.Phone.CodeTTLSeconds = 300
	}
	if cfg.Auth.Phone.SendCooldownSeconds == 0 {
		cfg.Auth.Phone.SendCooldownSeconds = 60
	}
	if cfg.Auth.Phone.PhoneHourlyLimit == 0 {
		cfg.Auth.Phone.PhoneHourlyLimit = 5
	}
	if cfg.Auth.Phone.PhoneDailyLimit == 0 {
		cfg.Auth.Phone.PhoneDailyLimit = 10
	}
	if cfg.Auth.Phone.IPHourlyLimit == 0 {
		cfg.Auth.Phone.IPHourlyLimit = 30
	}
	if cfg.Auth.Phone.MaxVerifyAttempts == 0 {
		cfg.Auth.Phone.MaxVerifyAttempts = 5
	}
	if len(cfg.Auth.Phone.AllowedCountryCodes) == 0 {
		cfg.Auth.Phone.AllowedCountryCodes = []string{"86"}
	}
	if cfg.Auth.Phone.CodePepper == "" {
		cfg.Auth.Phone.CodePepper = cfg.JWT.Secret
	}
	if cfg.SMS.Provider == "" {
		cfg.SMS.Provider = "mock"
	}
	if cfg.SMS.Aliyun.Endpoint == "" {
		cfg.SMS.Aliyun.Endpoint = "https://dysmsapi.aliyuncs.com/"
	}
	if cfg.Captcha.Provider == "" {
		cfg.Captcha.Provider = "mock"
	}
	if cfg.Captcha.Turnstile.Endpoint == "" {
		cfg.Captcha.Turnstile.Endpoint = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
	}
	if cfg.Storage.UploadURLTTL == 0 {
		cfg.Storage.UploadURLTTL = 900
	}
	if cfg.Storage.DownloadURLTTL == 0 {
		cfg.Storage.DownloadURLTTL = 900
	}
	if cfg.Storage.KeyPrefix == "" {
		cfg.Storage.KeyPrefix = "chat-assets"
	}
	if cfg.Asset.MaxImageSizeMB == 0 {
		cfg.Asset.MaxImageSizeMB = 10
	}
	if cfg.Asset.MaxAudioSizeMB == 0 {
		cfg.Asset.MaxAudioSizeMB = 20
	}
	if !cfg.Storage.PrivateRead {
		cfg.Storage.PrivateRead = true
	}
	if cfg.Log.Level == "" {
		cfg.Log.Level = "debug"
	}
	if cfg.Log.Format == "" {
		cfg.Log.Format = "console"
	}

	return &cfg, nil
}

// ConnMaxLifetimeDuration returns the connection max lifetime as time.Duration
func (d *DatabaseConfig) ConnMaxLifetimeDuration() time.Duration {
	return time.Duration(d.ConnMaxLifetime) * time.Second
}

func bindEnvKeys(v *viper.Viper, keys ...string) {
	for _, key := range keys {
		_ = v.BindEnv(key)
	}
}
