package storage

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

type S3Config struct {
	Bucket         string
	Region         string
	Endpoint       string
	PublicEndpoint string
	AccessKey      string
	SecretKey      string
	SSL            bool
}

type S3Provider struct {
	client           *minio.Client
	presignClient    *minio.Client
	bucket           string
	internalEndpoint string
	publicEndpoint   string
}

var _ ObjectStorageProvider = (*S3Provider)(nil)

func NewS3Provider(cfg S3Config) (*S3Provider, error) {
	bucket := strings.TrimSpace(cfg.Bucket)
	if bucket == "" || strings.TrimSpace(cfg.Endpoint) == "" {
		return nil, fmt.Errorf("s3 bucket and endpoint are required")
	}
	if strings.TrimSpace(cfg.AccessKey) == "" || strings.TrimSpace(cfg.SecretKey) == "" {
		return nil, fmt.Errorf("s3 access_key and secret_key are required")
	}

	internalEndpoint, internalSecure, err := normalizeS3Endpoint(cfg.Endpoint, cfg.SSL)
	if err != nil {
		return nil, fmt.Errorf("normalize s3 endpoint: %w", err)
	}

	publicRaw := strings.TrimSpace(cfg.PublicEndpoint)
	if publicRaw == "" {
		publicRaw = cfg.Endpoint
	}
	publicEndpoint, publicSecure, err := normalizeS3Endpoint(publicRaw, cfg.SSL)
	if err != nil {
		return nil, fmt.Errorf("normalize s3 public endpoint: %w", err)
	}

	client, err := newMinIOClient(internalEndpoint, internalSecure, cfg.Region, cfg.AccessKey, cfg.SecretKey)
	if err != nil {
		return nil, fmt.Errorf("create s3 client: %w", err)
	}
	presignClient := client
	if publicEndpoint != internalEndpoint || publicSecure != internalSecure {
		presignClient, err = newMinIOClient(publicEndpoint, publicSecure, cfg.Region, cfg.AccessKey, cfg.SecretKey)
		if err != nil {
			return nil, fmt.Errorf("create s3 presign client: %w", err)
		}
	}

	return &S3Provider{
		client:           client,
		presignClient:    presignClient,
		bucket:           bucket,
		internalEndpoint: internalEndpoint,
		publicEndpoint:   publicEndpoint,
	}, nil
}

func newMinIOClient(endpoint string, secure bool, region string, accessKey string, secretKey string) (*minio.Client, error) {
	return minio.New(endpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: secure,
		Region: strings.TrimSpace(region),
	})
}

func normalizeS3Endpoint(raw string, defaultSecure bool) (string, bool, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", false, fmt.Errorf("endpoint is required")
	}

	secure := defaultSecure
	parseTarget := trimmed
	if strings.Contains(trimmed, "://") {
		parsed, err := url.Parse(trimmed)
		if err != nil {
			return "", false, err
		}
		switch strings.ToLower(parsed.Scheme) {
		case "http":
			secure = false
		case "https":
			secure = true
		default:
			return "", false, fmt.Errorf("unsupported endpoint scheme %q", parsed.Scheme)
		}
		parseTarget = parsed.Host
		if parsed.Path != "" && parsed.Path != "/" {
			return "", false, fmt.Errorf("endpoint path is not supported")
		}
	}

	endpoint := strings.Trim(strings.TrimRight(parseTarget, "/"), " ")
	if endpoint == "" {
		return "", false, fmt.Errorf("endpoint host is required")
	}
	return endpoint, secure, nil
}

func (p *S3Provider) Provider() string { return "s3" }

func (p *S3Provider) Bucket() string { return p.bucket }

func (p *S3Provider) CreatePresignedUpload(ctx context.Context, objectKey string, contentType string, expires time.Duration) (*PresignedUpload, error) {
	signedURL, err := p.presignClient.PresignedPutObject(ctx, p.bucket, objectKey, expires)
	if err != nil {
		return nil, fmt.Errorf("create s3 presigned upload url: %w", err)
	}

	headers := map[string]string{}
	if contentType != "" {
		headers["Content-Type"] = contentType
	}

	return &PresignedUpload{
		Method:    http.MethodPut,
		URL:       signedURL.String(),
		Headers:   headers,
		ExpiresAt: time.Now().Add(expires),
	}, nil
}

func (p *S3Provider) CreatePresignedDownload(ctx context.Context, objectKey string, expires time.Duration) (string, time.Time, error) {
	signedURL, err := p.presignClient.PresignedGetObject(ctx, p.bucket, objectKey, expires, nil)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("create s3 presigned download url: %w", err)
	}

	expiresAt := time.Now().Add(expires)
	return signedURL.String(), expiresAt, nil
}

func (p *S3Provider) StatObject(ctx context.Context, objectKey string) (*ObjectInfo, error) {
	info, err := p.client.StatObject(ctx, p.bucket, objectKey, minio.StatObjectOptions{})
	if err != nil {
		return nil, err
	}

	lastModified := info.LastModified
	return &ObjectInfo{
		ETag:          strings.Trim(info.ETag, `"`),
		ContentType:   info.ContentType,
		ContentLength: info.Size,
		LastModified:  &lastModified,
	}, nil
}

func (p *S3Provider) PutObject(ctx context.Context, input PutObjectInput) (*ObjectInfo, error) {
	info, err := p.client.PutObject(ctx, p.bucket, input.ObjectKey, input.Reader, input.ContentLength, minio.PutObjectOptions{
		ContentType: input.ContentType,
	})
	if err != nil {
		return nil, err
	}

	return &ObjectInfo{
		ETag:          strings.Trim(info.ETag, `"`),
		ContentType:   input.ContentType,
		ContentLength: input.ContentLength,
	}, nil
}

func (p *S3Provider) DeleteObject(ctx context.Context, objectKey string) error {
	return p.client.RemoveObject(ctx, p.bucket, objectKey, minio.RemoveObjectOptions{})
}

func (p *S3Provider) CreateInternalDownload(ctx context.Context, key string, expires time.Duration) (string, error) {
	url, err := p.client.PresignedGetObject(ctx, p.bucket, key, expires, nil)
	if err != nil {
		return "", err
	}
	return url.String(), nil
}
