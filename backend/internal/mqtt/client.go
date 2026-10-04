package mqtt

import (
	"fmt"
	"time"

	mqtt "github.com/eclipse/paho.mqtt.golang"
	"github.com/google/uuid"
	"github.com/rs/zerolog"
)

// Client wraps the MQTT consumer used by the backend persistence service.
type Client struct {
	client  mqtt.Client
	log     zerolog.Logger
	cfg     MQTTConfig
	ingress MessageIngress
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

	opts := mqtt.NewClientOptions().
		AddBroker(c.cfg.Broker).
		SetClientID(c.cfg.ClientID).
		SetAutoReconnect(c.cfg.AutoReconnect).
		SetConnectRetry(true).
		SetConnectRetryInterval(time.Duration(c.cfg.ReconnectDelay) * time.Second).
		SetKeepAlive(30 * time.Second).
		SetCleanSession(false).
		SetDefaultPublishHandler(c.defaultHandler).
		SetOnConnectHandler(c.onConnect).
		SetConnectionLostHandler(c.onConnectionLost).
		SetReconnectingHandler(c.onReconnecting)

	if c.cfg.Username != "" {
		opts.SetUsername(c.cfg.Username)
		opts.SetPassword(c.cfg.Password)
	}

	c.client = mqtt.NewClient(opts)

	token := c.client.Connect()
	if !token.WaitTimeout(initialConnectTimeout) {
		c.client.Disconnect(250)
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
	topic := fmt.Sprintf("%s/#", c.cfg.TopicPrefix)
	c.log.Info().Str("topic", topic).Msg("MQTT connected, subscribing to persistence topics")

	if token := client.Subscribe(topic, c.cfg.QOS, c.handleMessage); token.Wait() && token.Error() != nil {
		c.log.Error().Err(token.Error()).Str("topic", topic).Msg("failed to subscribe")
		return
	}

	c.log.Info().Str("topic", topic).Msg("subscribed to MQTT topic")
}

func (c *Client) onConnectionLost(client mqtt.Client, err error) {
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
	if c.client != nil {
		c.client.Disconnect(3000)
	}
	c.log.Info().Msg("MQTT client disconnected")
}

// IsConnected returns whether the client is connected.
func (c *Client) IsConnected() bool {
	return c.client != nil && c.client.IsConnected()
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
	if c.client == nil || !c.client.IsConnectionOpen() {
		return fmt.Errorf("broker unavailable")
	}
	token := c.client.Publish(topic, 1, false, payload)
	if !token.WaitTimeout(3 * time.Second) {
		return fmt.Errorf("broker publish timeout")
	}
	return token.Error()
}
