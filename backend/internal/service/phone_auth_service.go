package service

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"math/big"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/jwt"
	"gorm.io/gorm"
)

var (
	ErrPhoneAuthDisabled = errors.New("phone auth is disabled")
	ErrInvalidPhone      = errors.New("invalid phone number")
	ErrPhoneRateLimited  = errors.New("phone verification rate limit exceeded")
	ErrInvalidPhoneCode  = errors.New("invalid or expired verification code")
)

type PhoneCodeRequest struct {
	Phone        string `json:"phone" binding:"required"`
	CaptchaToken string `json:"captcha_token" binding:"required"`
	Purpose      string `json:"purpose"`
}

type PhoneLoginRequest struct {
	Phone string `json:"phone" binding:"required"`
	Code  string `json:"code" binding:"required"`
}

type PhoneAuthService struct {
	userRepo   *repository.UserRepository
	auditRepo  *repository.AuditLogRepository
	jwtManager *jwt.Manager
	store      PhoneCodeStore
	captcha    CaptchaProvider
	sms        SMSProvider
	cfg        config.PhoneAuthConfig
}

func NewPhoneAuthService(
	userRepo *repository.UserRepository,
	auditRepo *repository.AuditLogRepository,
	jwtManager *jwt.Manager,
	store PhoneCodeStore,
	captcha CaptchaProvider,
	sms SMSProvider,
	cfg config.PhoneAuthConfig,
) *PhoneAuthService {
	return &PhoneAuthService{
		userRepo:   userRepo,
		auditRepo:  auditRepo,
		jwtManager: jwtManager,
		store:      store,
		captcha:    captcha,
		sms:        sms,
		cfg:        cfg,
	}
}

func (s *PhoneAuthService) SendCooldownSeconds() int {
	return s.cfg.SendCooldownSeconds
}

func (s *PhoneAuthService) RequestCode(ctx context.Context, req PhoneCodeRequest, ip, userAgent string) error {
	if !s.cfg.Enabled {
		return ErrPhoneAuthDisabled
	}

	countryCode, phoneNumber, err := NormalizeMainlandPhone(req.Phone)
	if err != nil {
		s.auditCodeRequest(nil, ip, userAgent, 400, "invalid_phone")
		return err
	}
	if !s.isCountryAllowed(countryCode) {
		s.auditCodeRequest(&phoneNumber, ip, userAgent, 400, "country_not_allowed")
		return ErrInvalidPhone
	}
	if err := s.captcha.Verify(ctx, req.CaptchaToken, ip); err != nil {
		s.auditCodeRequest(&phoneNumber, ip, userAgent, 400, "captcha_failed")
		return ErrCaptchaInvalid
	}
	if err := s.enforceSendLimits(ctx, countryCode, phoneNumber, ip); err != nil {
		s.auditCodeRequest(&phoneNumber, ip, userAgent, 429, "rate_limited")
		return err
	}

	code, err := s.generateCode()
	if err != nil {
		return err
	}
	purpose := normalizePhonePurpose(req.Purpose)
	codeTTL := time.Duration(s.cfg.CodeTTLSeconds) * time.Second
	codeKey := s.codeKey(purpose, countryCode, phoneNumber)
	attemptKey := s.attemptKey(purpose, countryCode, phoneNumber)
	if err := s.store.Set(ctx, codeKey, s.codeHash(purpose, countryCode, phoneNumber, code), codeTTL); err != nil {
		return err
	}
	if err := s.store.Delete(ctx, attemptKey); err != nil {
		return err
	}
	if err := s.sms.SendCode(ctx, countryCode, phoneNumber, code); err != nil {
		_ = s.store.Delete(ctx, codeKey, attemptKey)
		return err
	}

	s.auditCodeRequest(&phoneNumber, ip, userAgent, 200, "")
	return nil
}

func (s *PhoneAuthService) LoginOrRegister(ctx context.Context, req PhoneLoginRequest, ip, userAgent string) (*TokenResponse, *model.User, bool, error) {
	if !s.cfg.Enabled {
		return nil, nil, false, ErrPhoneAuthDisabled
	}

	countryCode, phoneNumber, err := NormalizeMainlandPhone(req.Phone)
	if err != nil {
		return nil, nil, false, err
	}
	if !s.isCountryAllowed(countryCode) {
		return nil, nil, false, ErrInvalidPhone
	}
	if err := s.verifyCode(ctx, "login", countryCode, phoneNumber, req.Code); err != nil {
		return nil, nil, false, err
	}

	user, created, err := s.getOrCreatePhoneUser(ctx, countryCode, phoneNumber)
	if err != nil {
		return nil, nil, false, err
	}
	if user.Status == model.UserStatusBanned {
		return nil, nil, false, ErrUserBanned
	}

	_ = s.userRepo.UpdateLastLogin(ctx, user.ID, ip)
	tokens, err := s.generateTokens(user)
	if err != nil {
		return nil, nil, false, err
	}

	action := model.AuditActionPhoneLogin
	code := 200
	if created {
		action = model.AuditActionPhoneRegister
		code = 201
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		UserID:       &user.ID,
		Action:       string(action),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(code),
		Metadata: model.JSONMap{
			"phone_country_code": countryCode,
		},
	})

	return tokens, user, created, nil
}

func NormalizeMainlandPhone(raw string) (string, string, error) {
	phone := strings.TrimSpace(raw)
	phone = strings.ReplaceAll(phone, " ", "")
	phone = strings.ReplaceAll(phone, "-", "")
	phone = strings.ReplaceAll(phone, "(", "")
	phone = strings.ReplaceAll(phone, ")", "")
	if strings.HasPrefix(phone, "+86") {
		phone = strings.TrimPrefix(phone, "+86")
	} else if strings.HasPrefix(phone, "0086") {
		phone = strings.TrimPrefix(phone, "0086")
	}

	ok, _ := regexp.MatchString(`^1[3-9][0-9]{9}$`, phone)
	if !ok {
		return "", "", ErrInvalidPhone
	}
	return "86", phone, nil
}

func (s *PhoneAuthService) enforceSendLimits(ctx context.Context, countryCode string, phoneNumber string, ip string) error {
	now := time.Now()
	cooldownOK, err := s.store.SetNX(ctx, fmt.Sprintf("phoneauth:cooldown:%s:%s", countryCode, phoneNumber), "1", time.Duration(s.cfg.SendCooldownSeconds)*time.Second)
	if err != nil {
		return err
	}
	if !cooldownOK {
		return ErrPhoneRateLimited
	}

	phoneHour, err := s.store.IncrWithTTL(ctx, fmt.Sprintf("phoneauth:limit:phone-hour:%s:%s:%s", now.Format("2006010215"), countryCode, phoneNumber), time.Hour)
	if err != nil {
		return err
	}
	if int(phoneHour) > s.cfg.PhoneHourlyLimit {
		return ErrPhoneRateLimited
	}

	phoneDay, err := s.store.IncrWithTTL(ctx, fmt.Sprintf("phoneauth:limit:phone-day:%s:%s:%s", now.Format("20060102"), countryCode, phoneNumber), 24*time.Hour)
	if err != nil {
		return err
	}
	if int(phoneDay) > s.cfg.PhoneDailyLimit {
		return ErrPhoneRateLimited
	}

	ipHour, err := s.store.IncrWithTTL(ctx, fmt.Sprintf("phoneauth:limit:ip-hour:%s:%s", now.Format("2006010215"), ip), time.Hour)
	if err != nil {
		return err
	}
	if int(ipHour) > s.cfg.IPHourlyLimit {
		return ErrPhoneRateLimited
	}

	return nil
}

func (s *PhoneAuthService) verifyCode(ctx context.Context, purpose, countryCode, phoneNumber, code string) error {
	code = strings.TrimSpace(code)
	if code == "" {
		return ErrInvalidPhoneCode
	}

	codeKey := s.codeKey(purpose, countryCode, phoneNumber)
	attemptKey := s.attemptKey(purpose, countryCode, phoneNumber)
	attempts, err := s.store.IncrWithTTL(ctx, attemptKey, time.Duration(s.cfg.CodeTTLSeconds)*time.Second)
	if err != nil {
		return err
	}
	if int(attempts) > s.cfg.MaxVerifyAttempts {
		_ = s.store.Delete(ctx, codeKey, attemptKey)
		return ErrInvalidPhoneCode
	}

	stored, err := s.store.Get(ctx, codeKey)
	if err != nil {
		if errors.Is(err, ErrPhoneCodeNotFound) {
			return ErrInvalidPhoneCode
		}
		return err
	}
	actual := s.codeHash(purpose, countryCode, phoneNumber, code)
	if subtle.ConstantTimeCompare([]byte(stored), []byte(actual)) != 1 {
		return ErrInvalidPhoneCode
	}

	return s.store.Delete(ctx, codeKey, attemptKey)
}

func (s *PhoneAuthService) getOrCreatePhoneUser(ctx context.Context, countryCode, phoneNumber string) (*model.User, bool, error) {
	user, err := s.userRepo.GetByPhone(ctx, countryCode, phoneNumber)
	if err == nil {
		return user, false, nil
	}
	if !errors.Is(err, gorm.ErrRecordNotFound) {
		return nil, false, err
	}

	now := time.Now()
	nickname := "用户" + phoneNumber[len(phoneNumber)-4:]
	user = &model.User{
		ID:               uuid.New(),
		Username:         "",
		PhoneCountryCode: &countryCode,
		PhoneNumber:      &phoneNumber,
		PhoneVerifiedAt:  &now,
		AuthProvider:     "phone",
		Nickname:         &nickname,
		Status:           model.UserStatusActive,
		CreatedAt:        now,
		UpdatedAt:        now,
	}

	for i := 0; i < 5; i++ {
		username, err := s.uniquePhoneUsername(ctx, phoneNumber)
		if err != nil {
			return nil, false, err
		}
		user.Username = username
		if err := s.userRepo.Create(ctx, user); err == nil {
			return user, true, nil
		}
	}

	user, err = s.userRepo.GetByPhone(ctx, countryCode, phoneNumber)
	if err == nil {
		return user, false, nil
	}
	return nil, false, err
}

func (s *PhoneAuthService) uniquePhoneUsername(ctx context.Context, phoneNumber string) (string, error) {
	for i := 0; i < 10; i++ {
		suffix, err := randomHex(3)
		if err != nil {
			return "", err
		}
		username := "u" + phoneNumber[len(phoneNumber)-4:] + suffix
		exists, err := s.userRepo.ExistsByUsername(ctx, username)
		if err != nil {
			return "", err
		}
		if !exists {
			return username, nil
		}
	}
	return "", ErrUserAlreadyExists
}

func (s *PhoneAuthService) generateTokens(user *model.User) (*TokenResponse, error) {
	accessToken, refreshToken, err := s.jwtManager.GenerateTokenPair(user.ID, user.Username)
	if err != nil {
		return nil, err
	}
	return &TokenResponse{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    7200,
		TokenType:    "Bearer",
	}, nil
}

func (s *PhoneAuthService) generateCode() (string, error) {
	if code := strings.TrimSpace(s.cfg.MockCode); code != "" {
		return code, nil
	}
	max := big.NewInt(1_000_000)
	n, err := rand.Int(rand.Reader, max)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func (s *PhoneAuthService) codeHash(purpose, countryCode, phoneNumber, code string) string {
	mac := hmac.New(sha256.New, []byte(s.cfg.CodePepper))
	_, _ = mac.Write([]byte(purpose))
	_, _ = mac.Write([]byte(":"))
	_, _ = mac.Write([]byte(countryCode))
	_, _ = mac.Write([]byte(":"))
	_, _ = mac.Write([]byte(phoneNumber))
	_, _ = mac.Write([]byte(":"))
	_, _ = mac.Write([]byte(code))
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *PhoneAuthService) codeKey(purpose, countryCode, phoneNumber string) string {
	return fmt.Sprintf("phoneauth:code:%s:%s:%s", purpose, countryCode, phoneNumber)
}

func (s *PhoneAuthService) attemptKey(purpose, countryCode, phoneNumber string) string {
	return fmt.Sprintf("phoneauth:attempts:%s:%s:%s", purpose, countryCode, phoneNumber)
}

func (s *PhoneAuthService) isCountryAllowed(countryCode string) bool {
	for _, allowed := range s.cfg.AllowedCountryCodes {
		if strings.TrimPrefix(strings.TrimSpace(allowed), "+") == countryCode {
			return true
		}
	}
	return false
}

func (s *PhoneAuthService) auditCodeRequest(phoneNumber *string, ip, userAgent string, statusCode int, reason string) {
	metadata := model.JSONMap{}
	if reason != "" {
		metadata["reason"] = reason
	}
	if phoneNumber != nil {
		metadata["phone_suffix"] = suffix(*phoneNumber, 4)
	}
	s.auditRepo.CreateAsync(&model.AuditLog{
		Action:       string(model.AuditActionSMSCodeRequest),
		IPAddress:    &ip,
		UserAgent:    &userAgent,
		ResponseCode: intPtr(statusCode),
		Metadata:     metadata,
	})
}

func normalizePhonePurpose(value string) string {
	value = strings.TrimSpace(strings.ToLower(value))
	if value == "" {
		return "login"
	}
	return "login"
}

func randomHex(byteCount int) (string, error) {
	buffer := make([]byte, byteCount)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func suffix(value string, length int) string {
	if len(value) <= length {
		return value
	}
	return value[len(value)-length:]
}
