package mqtt

import (
	"context"
	"fmt"
	"net"
	"testing"
	"time"

	"github.com/eclipse/paho.mqtt.golang/packets"
	"github.com/rs/zerolog"
)

// Exercise actual Paho CONNECT/SUBSCRIBE traffic: CONNECT succeeds before the
// denied asynchronous SUBACK, so readiness must remain false and Run must retry.
func TestRunRetriesRejectedSubscription(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	rejected := make(chan struct{}, 1)
	received := make(chan string, 1)
	finished := make(chan error, 1)
	release := make(chan struct{})
	defer close(release)
	go func() {
		run := func() error {
			for attempt := 0; attempt < 2; attempt++ {
				conn, err := listener.Accept()
				if err != nil {
					return err
				}
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
				packet, err := packets.ReadPacket(conn)
				if err != nil {
					return err
				}
				if _, ok := packet.(*packets.ConnectPacket); !ok {
					return fmt.Errorf("expected CONNECT")
				}
				if err = packets.NewControlPacket(packets.Connack).Write(conn); err != nil {
					return err
				}
				packet, err = packets.ReadPacket(conn)
				if err != nil {
					return err
				}
				sub, ok := packet.(*packets.SubscribePacket)
				if !ok {
					return fmt.Errorf("expected SUBSCRIBE")
				}
				reply := packets.NewControlPacket(packets.Suback).(*packets.SubackPacket)
				reply.MessageID = sub.MessageID
				reply.ReturnCodes = []byte{1}
				if attempt == 0 {
					reply.ReturnCodes = []byte{0x80}
				}
				if err = reply.Write(conn); err != nil {
					return err
				}
				if attempt == 0 {
					rejected <- struct{}{}
					// The broker keeps this rejected connection open. The retry owner must
					// disconnect it and establish a new subscription by itself.
					_, _ = packets.ReadPacket(conn)
					_ = conn.Close()
					continue
				}
				publish := packets.NewControlPacket(packets.Publish).(*packets.PublishPacket)
				publish.Qos = 1
				publish.MessageID = 7
				publish.TopicName = "chat/group/retry"
				publish.Payload = []byte("persist after retry")
				if err = publish.Write(conn); err != nil {
					return err
				}
				packet, err = packets.ReadPacket(conn)
				if err != nil {
					return err
				}
				ack, ok := packet.(*packets.PubackPacket)
				if !ok || ack.MessageID != 7 {
					return fmt.Errorf("missing PUBACK after durable ingress")
				}
				finished <- nil
				<-release
				return nil
			}
			return fmt.Errorf("subscription retry did not complete")
		}
		if err := run(); err != nil {
			finished <- err
		}
	}()
	client := NewClient(MQTTConfig{Broker: "tcp://" + listener.Addr().String(), ClientID: "retry-consumer"}, zerolog.Nop(), intake(func(_ string, payload []byte) error { received <- string(payload); return nil }))
	ctx, cancel := context.WithCancel(context.Background())
	running := make(chan struct{})
	go func() { defer close(running); client.Run(ctx) }()
	defer func() {
		cancel()
		client.Disconnect()
		select {
		case <-running:
		case <-time.After(6 * time.Second):
			t.Error("retry loop failed to stop")
		}
	}()
	select {
	case <-rejected:
	case err := <-finished:
		t.Fatal(err)
	case <-time.After(3 * time.Second):
		t.Fatal("initial SUBACK missing")
	}
	if client.IsConnected() {
		t.Fatal("denied SUBACK reported ready")
	}
	select {
	case data := <-received:
		if data != "persist after retry" {
			t.Fatal("payload changed")
		}
	case <-time.After(6 * time.Second):
		t.Fatal("consumer did not retry denied SUBACK")
	}
	select {
	case err := <-finished:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("message was not acknowledged")
	}
	if !client.IsConnected() {
		t.Fatal("accepted replacement subscription did not become ready")
	}
}
