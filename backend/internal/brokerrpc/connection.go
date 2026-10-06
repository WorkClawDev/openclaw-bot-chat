package brokerrpc

import (
	"crypto/tls"
	"crypto/x509"
	"errors"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"os"
)

// Dial opens the generic authorization management connection, independently of the API.
func Dial(settings config.BrokerSecurityConfig) (*grpc.ClientConn, error) {
	var transport credentials.TransportCredentials
	if settings.Insecure {
		if settings.CAFile != "" || settings.CertFile != "" || settings.KeyFile != "" {
			return nil, errors.New("insecure authz RPC cannot use TLS options")
		}
		transport = insecure.NewCredentials()
	} else {
		tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
		if settings.CAFile != "" {
			raw, err := os.ReadFile(settings.CAFile)
			if err != nil {
				return nil, err
			}
			pool := x509.NewCertPool()
			if !pool.AppendCertsFromPEM(raw) {
				return nil, errors.New("invalid authz CA")
			}
			tlsConfig.RootCAs = pool
		}
		if settings.CertFile != "" || settings.KeyFile != "" {
			cert, err := tls.LoadX509KeyPair(settings.CertFile, settings.KeyFile)
			if err != nil {
				return nil, err
			}
			tlsConfig.Certificates = []tls.Certificate{cert}
		}
		transport = credentials.NewTLS(tlsConfig)
	}
	conn, err := grpc.NewClient(settings.Address, grpc.WithTransportCredentials(transport), grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(4*1024*1024), grpc.MaxCallSendMsgSize(4*1024*1024)))
	if err != nil {
		return nil, err
	}
	return conn, nil
}
