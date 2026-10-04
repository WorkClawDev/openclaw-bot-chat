package mqtt

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

// Client wraps the MQTT consumer used by the backend persistence service.
type Client struct {
	client     mqtt.Client
	log        zerolog.Logger
	cfg        MQTTConfig
	ingress    MessageIngress
	subscribed atomic.Bool
	mu         sync.RWMutex
}

// MQTTConfig holds MQTT client configuration.
type MQTTConfig struct {
	Broker         string
	ClientID       string
	Username       string
	Password       string
	TopicPrefix    string
	QOS            byte
	AutoReconnect  bool
	ReconnectDelay int
	TLSCAFile      string
	TLSCertFile    string
	TLSKeyFile     string
	TLSServerName  string
}

// NewClient creates a new MQTT consumer.
func NewClient(cfg MQTTConfig, log zerolog.Logger, ingress MessageIngress) *Client {
	if cfg.ClientID == "" {
		cfg.ClientID = fmt.Sprintf("openclaw-backend-%s", uuid.New().String()[:8])
	}
	if cfg.TopicPrefix == "" {
		cfg.TopicPrefix = "chat"
	}
	if cfg.QOS == 0 {
		cfg.QOS = 1
	}

	return &Client{
		cfg:     cfg,
		log:     log,
		ingress: ingress,
	}
}

// Connect establishes connection to the MQTT broker and subscribes to all chat topics.
func (c *Client) Connect() error {
	const initialConnectTimeout = 5 * time.Second
	broker, tlsConfig, err := brokerTLS(c.cfg)
	if err != nil {
		return err
	}

	opts := mqtt.NewClientOptions().
		AddBroker(broker).
		SetClientID(c.cfg.ClientID).
		SetAutoReconnect(c.cfg.AutoReconnect).
		SetConnectRetry(false).
		SetConnectRetryInterval(time.Duration(c.cfg.ReconnectDelay) * time.Second).
		SetKeepAlive(30 * time.Second).
		SetCleanSession(false).
		SetDefaultPublishHandler(c.defaultHandler).
		SetOnConnectHandler(c.onConnect).
		SetConnectionLostHandler(c.onConnectionLost).
		SetReconnectingHandler(c.onReconnecting)
	if tlsConfig != nil {
		opts.SetTLSConfig(tlsConfig)
	}

	if c.cfg.Username != "" {
		opts.SetUsername(c.cfg.Username)
		opts.SetPassword(c.cfg.Password)
	}

	client := mqtt.NewClient(opts)
	c.mu.Lock()
	c.client = client
	c.mu.Unlock()
	token := client.Connect()
	if !token.WaitTimeout(initialConnectTimeout) {
		client.Disconnect(250)
		return fmt.Errorf("timed out connecting to MQTT broker after %s", initialConnectTimeout)
	}
	if token.Error() != nil {
		return fmt.Errorf("failed to connect to MQTT broker: %w", token.Error())
	}

	c.log.Info().Str("broker", c.cfg.Broker).Msg("connected to MQTT broker")
	return nil
}

func (c *Client) defaultHandler(client mqtt.Client, msg mqtt.Message) {
	c.log.Debug().Str("topic", msg.Topic()).Int("qos", int(msg.Qos())).Msg("MQTT message received")
}

func (c *Client) onConnect(client mqtt.Client) {
	c.subscribed.Store(false)
	topic := fmt.Sprintf("%s/#", c.cfg.TopicPrefix)
	c.log.Info().Str("topic", topic).Msg("MQTT connected, subscribing to persistence topics")

	token := client.Subscribe(topic, c.cfg.QOS, c.handleMessage)
	if !token.WaitTimeout(5 * time.Second) {
		c.log.Error().Str("topic", topic).Msg("subscription timed out")
		client.Disconnect(250)
		return
	}
	if token.Error() != nil {
		c.log.Error().Err(token.Error()).Str("topic", topic).Msg("failed to subscribe")
		return
	}
	if subscription, ok := token.(*mqtt.SubscribeToken); ok && subscription.Result()[topic] == 0x80 {
		c.log.Error().Str("topic", topic).Msg("broker denied persistence subscription")
		return
	}

	c.log.Info().Str("topic", topic).Msg("subscribed to MQTT topic")
	c.subscribed.Store(true)
}

func (c *Client) onConnectionLost(client mqtt.Client, err error) {
	c.subscribed.Store(false)
	c.log.Warn().Err(err).Msg("MQTT connection lost")
}

func (c *Client) onReconnecting(client mqtt.Client, opts *mqtt.ClientOptions) {
	c.log.Warn().Msg("MQTT reconnecting")
}

func (c *Client) handleMessage(client mqtt.Client, msg mqtt.Message) {
	if c.ingress == nil {
		return
	}
	if err := c.ingress.HandleIncomingMessage(msg.Topic(), msg.Payload()); err != nil {
		c.log.Error().Err(err).Str("topic", msg.Topic()).Msg("failed to persist incoming MQTT message")
	}
}

// Disconnect gracefully disconnects from the MQTT broker.
func (c *Client) Disconnect() {
	if client := c.getClient(); client != nil {
		client.Disconnect(3000)
	}
	c.log.Info().Msg("MQTT client disconnected")
}

// IsConnected returns whether the client is connected.
func (c *Client) IsConnected() bool {
	client := c.getClient()
	return client != nil && client.IsConnected() && c.subscribed.Load()
}

// BuildTopic is a helper to build a full MQTT topic path.
func BuildTopic(prefix string, topicParts ...string) string {
	all := append([]string{prefix}, topicParts...)
	result := all[0]
	for _, p := range all[1:] {
		result += "/" + p
	}
	return result
}

func (c *Client) PublishAgentNotice(topic string, payload []byte) error {
	client := c.getClient()
	if client == nil || !client.IsConnectionOpen() {
		return fmt.Errorf("broker unavailable")
	}
	token := client.Publish(topic, 1, false, payload)
	if !token.WaitTimeout(3 * time.Second) {
		return fmt.Errorf("broker publish timeout")
	}
	return token.Error()
}

func (c *Client) getClient() mqtt.Client {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.client
}
