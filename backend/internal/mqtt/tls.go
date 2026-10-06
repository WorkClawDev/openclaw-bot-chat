package mqtt

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/url"
	"os"
)

func brokerTLS(cfg MQTTConfig) (string, *tls.Config, error) {
	u, err := url.Parse(cfg.Broker)
	if err != nil || u.Hostname() == "" || u.User != nil {
		return "", nil, fmt.Errorf("invalid MQTT broker URL; use separate credential settings")
	}
	switch u.Scheme {
	case "mqtt":
		u.Scheme = "tcp"
	case "mqtts":
		u.Scheme = "ssl"
	case "tcp", "ssl", "tls", "ws", "wss":
	default:
		return "", nil, fmt.Errorf("unsupported MQTT broker scheme")
	}
	secure := u.Scheme == "ssl" || u.Scheme == "tls" || u.Scheme == "wss"
	if !secure {
		if cfg.TLSCAFile != "" || cfg.TLSCertFile != "" || cfg.TLSKeyFile != "" || cfg.TLSServerName != "" {
			return "", nil, fmt.Errorf("MQTT TLS settings require a secure broker URL")
		}
		return u.String(), nil, nil
	}
	settings := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: cfg.TLSServerName}
	if cfg.TLSCAFile != "" {
		roots, err := x509.SystemCertPool()
		if err != nil {
			roots = x509.NewCertPool()
		}
		data, err := os.ReadFile(cfg.TLSCAFile)
		if err != nil {
			return "", nil, fmt.Errorf("read MQTT CA certificate: %w", err)
		}
		if !roots.AppendCertsFromPEM(data) {
			return "", nil, fmt.Errorf("MQTT CA file contains no certificates")
		}
		settings.RootCAs = roots
	}
	if cfg.TLSCertFile != "" || cfg.TLSKeyFile != "" {
		pair, err := tls.LoadX509KeyPair(cfg.TLSCertFile, cfg.TLSKeyFile)
		if err != nil {
			return "", nil, fmt.Errorf("load MQTT client certificate: %w", err)
		}
		settings.Certificates = []tls.Certificate{pair}
	}
	return u.String(), settings, nil
}
