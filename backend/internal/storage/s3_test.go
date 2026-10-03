package storage

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/openclaw-bot-chat/backend/internal/config"
)

func TestNormalizeS3Endpoint(t *testing.T) {
	tests := []struct {
		name          string
		raw           string
		defaultSecure bool
		wantEndpoint  string
		wantSecure    bool
	}{
		{name: "plain inherits ssl false", raw: "minio:9000", defaultSecure: false, wantEndpoint: "minio:9000", wantSecure: false},
		{name: "plain inherits ssl true", raw: "minio:9000", defaultSecure: true, wantEndpoint: "minio:9000", wantSecure: true},
		{name: "http overrides ssl true", raw: "http://127.0.0.1:9000", defaultSecure: true, wantEndpoint: "127.0.0.1:9000", wantSecure: false},
		{name: "https overrides ssl false", raw: "https://s3.example.com", defaultSecure: false, wantEndpoint: "s3.example.com", wantSecure: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotEndpoint, gotSecure, err := normalizeS3Endpoint(tt.raw, tt.defaultSecure)
			if err != nil {
				t.Fatalf("normalizeS3Endpoint() error = %v", err)
			}
			if gotEndpoint != tt.wantEndpoint || gotSecure != tt.wantSecure {
				t.Fatalf("normalizeS3Endpoint() = (%q, %v), want (%q, %v)", gotEndpoint, gotSecure, tt.wantEndpoint, tt.wantSecure)
			}
		})
	}
}

func TestNormalizeS3EndpointRejectsPath(t *testing.T) {
	_, _, err := normalizeS3Endpoint("http://127.0.0.1:9000/path", false)
	if err == nil {
		t.Fatal("expected endpoint with path to be rejected")
	}
}

func TestNewProviderS3UsesNestedConfigWithTopLevelFallback(t *testing.T) {
	provider, err := NewProvider(config.StorageConfig{
		Provider: "s3",
		Bucket:   "top-bucket",
		Region:   "top-region",
		Endpoint: "top-endpoint:9000",
		S3: config.S3StorageConfig{
			Bucket:         "nested-bucket",
			Region:         "nested-region",
			Endpoint:       "nested-endpoint:9000",
			PublicEndpoint: "public-endpoint:9000",
			AccessKey:      "access",
			SecretKey:      "secret",
		},
	})
	if err != nil {
		t.Fatalf("NewProvider() error = %v", err)
	}

	s3, ok := provider.(*S3Provider)
	if !ok {
		t.Fatalf("NewProvider() type = %T, want *S3Provider", provider)
	}
	if s3.Bucket() != "nested-bucket" {
		t.Fatalf("Bucket() = %q, want nested-bucket", s3.Bucket())
	}
	if s3.internalEndpoint != "nested-endpoint:9000" {
		t.Fatalf("internalEndpoint = %q, want nested-endpoint:9000", s3.internalEndpoint)
	}
	if s3.publicEndpoint != "public-endpoint:9000" {
		t.Fatalf("publicEndpoint = %q, want public-endpoint:9000", s3.publicEndpoint)
	}

	provider, err = NewProvider(config.StorageConfig{
		Provider: "s3",
		Bucket:   "top-bucket",
		Region:   "top-region",
		Endpoint: "top-endpoint:9000",
		S3: config.S3StorageConfig{
			AccessKey: "access",
			SecretKey: "secret",
		},
	})
	if err != nil {
		t.Fatalf("NewProvider() fallback error = %v", err)
	}
	s3 = provider.(*S3Provider)
	if s3.Bucket() != "top-bucket" {
		t.Fatalf("fallback Bucket() = %q, want top-bucket", s3.Bucket())
	}
	if s3.internalEndpoint != "top-endpoint:9000" || s3.publicEndpoint != "top-endpoint:9000" {
		t.Fatalf("fallback endpoints = (%q, %q), want top-endpoint:9000", s3.internalEndpoint, s3.publicEndpoint)
	}
}

func TestNewS3ProviderRequiresConfig(t *testing.T) {
	_, err := NewS3Provider(S3Config{})
	if err == nil || !strings.Contains(err.Error(), "bucket and endpoint") {
		t.Fatalf("NewS3Provider() error = %v, want bucket/endpoint error", err)
	}

	_, err = NewS3Provider(S3Config{Bucket: "bucket", Endpoint: "minio:9000"})
	if err == nil || !strings.Contains(err.Error(), "access_key and secret_key") {
		t.Fatalf("NewS3Provider() error = %v, want credential error", err)
	}
}

func TestS3PresignedURLsUsePublicEndpoint(t *testing.T) {
	provider, err := NewS3Provider(S3Config{
		Bucket:         "bucket",
		Endpoint:       "minio:9000",
		PublicEndpoint: "http://127.0.0.1:9000",
		AccessKey:      "access",
		SecretKey:      "secret",
		Region:         "us-east-1",
		SSL:            true,
	})
	if err != nil {
		t.Fatalf("NewS3Provider() error = %v", err)
	}

	upload, err := provider.CreatePresignedUpload(context.Background(), "images/test.png", "image/png", time.Minute)
	if err != nil {
		t.Fatalf("CreatePresignedUpload() error = %v", err)
	}
	if upload.Method != http.MethodPut {
		t.Fatalf("upload method = %q, want PUT", upload.Method)
	}
	if upload.Headers["Content-Type"] != "image/png" {
		t.Fatalf("upload content-type header = %q, want image/png", upload.Headers["Content-Type"])
	}
	assertURLHost(t, upload.URL, "http", "127.0.0.1:9000")

	downloadURL, _, err := provider.CreatePresignedDownload(context.Background(), "images/test.png", time.Minute)
	if err != nil {
		t.Fatalf("CreatePresignedDownload() error = %v", err)
	}
	assertURLHost(t, downloadURL, "http", "127.0.0.1:9000")
	internal, err := provider.CreateInternalDownload(context.Background(), "images/test.png", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	assertURLHost(t, internal, "https", "minio:9000")
}

func assertURLHost(t *testing.T, raw string, wantScheme string, wantHost string) {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse URL %q: %v", raw, err)
	}
	if parsed.Scheme != wantScheme || parsed.Host != wantHost {
		t.Fatalf("URL = %q://%q, want %q://%q", parsed.Scheme, parsed.Host, wantScheme, wantHost)
	}
}
