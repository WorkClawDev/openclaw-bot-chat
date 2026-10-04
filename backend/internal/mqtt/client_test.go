package mqtt

import (
	"errors"
	"testing"
	"time"

	paho "github.com/eclipse/paho.mqtt.golang"
	"github.com/rs/zerolog"
)

type intake func(string, []byte) error

func (f intake) HandleIncomingMessage(t string, p []byte) error { return f(t, p) }

type testMessage struct {
	paho.Message
	acked bool
}

func (m *testMessage) Topic() string   { return "chat/group/test" }
func (m *testMessage) Payload() []byte { return []byte("payload") }
func (m *testMessage) Ack()            { m.acked = true }

type disconnectClient struct {
	paho.Client
	done chan struct{}
}

func (c *disconnectClient) Disconnect(uint) { close(c.done) }
func TestAcknowledgesOnlyDurableAppend(t *testing.T) {
	m := &testMessage{}
	c := NewClient(MQTTConfig{}, zerolog.Nop(), intake(func(string, []byte) error {
		if m.acked {
			t.Fatal("ACK before durable append")
		}
		return nil
	}))
	c.handleMessage(nil, m)
	if !m.acked {
		t.Fatal("durable append not acknowledged")
	}
	m = &testMessage{}
	transport := &disconnectClient{done: make(chan struct{})}
	c.ingress = intake(func(string, []byte) error { return errors.New("disk full") })
	c.handleMessage(transport, m)
	select {
	case <-transport.done:
	case <-time.After(time.Second):
		t.Fatal("failed intake did not disconnect")
	}
	if m.acked || !c.failed.Load() {
		t.Fatal("failed intake was acknowledged")
	}
}
