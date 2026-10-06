package mqtt

import (
	"crypto/tls"
	"encoding/pem"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestBrokerTLSVerifiesCertificatesAndHostnames(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	defer server.Close()
	address := strings.TrimPrefix(server.URL, "https://")
	ca := filepath.Join(t.TempDir(), "ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600); err != nil {
		t.Fatal(err)
	}
	broker, config, err := brokerTLS(MQTTConfig{Broker: "mqtts://" + address, TLSCAFile: ca})
	if err != nil || broker != "ssl://"+address || config.InsecureSkipVerify || config.MinVersion < tls.VersionTLS12 {
		t.Fatalf("invalid TLS settings: %v", err)
	}
	dialer := &net.Dialer{Timeout: time.Second}
	connection, err := tls.DialWithDialer(dialer, "tcp", address, config)
	if err != nil {
		t.Fatal(err)
	}
	connection.Close()
	config.ServerName = "wrong-host.invalid"
	if conn, err := tls.DialWithDialer(dialer, "tcp", address, config); err == nil {
		conn.Close()
		t.Fatal("hostname mismatch accepted")
	}
	_, untrusted, _ := brokerTLS(MQTTConfig{Broker: "mqtts://" + address})
	if conn, err := tls.DialWithDialer(dialer, "tcp", address, untrusted); err == nil {
		conn.Close()
		t.Fatal("untrusted certificate accepted")
	}
	for _, cfg := range []MQTTConfig{{Broker: "ftp://example.test"}, {Broker: "mqtt://user:secret@example.test"}, {Broker: "mqtt://example.test", TLSCAFile: ca}, {Broker: "mqtts://example.test", TLSCAFile: "missing"}, {Broker: "mqtts://example.test", TLSCertFile: ca}} {
		if _, _, err := brokerTLS(cfg); err == nil {
			t.Fatal("invalid broker configuration accepted")
		}
	}
}
