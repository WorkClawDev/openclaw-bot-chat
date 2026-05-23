package service

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"github.com/openclaw-bot-chat/backend/internal/repository"
)

// MessageService handles message operations
type MessageService struct {
	msgRepo   *repository.MessageRepository
	botRepo   *repository.BotRepository
	groupRepo *repository.GroupRepository
	assetRepo *repository.AssetRepository
	auditRepo *repository.AuditLogRepository
	assetSvc  *AssetService
}

// NewMessageService creates a new message service
func NewMessageService(
	msgRepo *repository.MessageRepository,
	botRepo *repository.BotRepository,
	groupRepo *repository.GroupRepository,
	assetRepo *repository.AssetRepository,
	auditRepo *repository.AuditLogRepository,
	assetSvc *AssetService,
) *MessageService {
	return &MessageService{
		msgRepo:   msgRepo,
		botRepo:   botRepo,
		groupRepo: groupRepo,
		assetRepo: assetRepo,
		auditRepo: auditRepo,
		assetSvc:  assetSvc,
	}
}

// HandleIncomingMessage persists a raw MQTT payload received by the transport layer.
func (s *MessageService) HandleIncomingMessage(topic string, payload []byte) error {
	var msgPayload MessagePayload
	if err := json.Unmarshal(payload, &msgPayload); err != nil {
		return fmt.Errorf("unmarshal MQTT payload: %w", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	normalized := normalizeIncomingMessage(topic, msgPayload)
	if declared := NormalizeConversationReference(firstNonEmpty(msgPayload.ConversationID, msgPayload.Topic)); declared != "" && declared != normalized.conversationID {
		return fmt.Errorf("message conversation_id does not match MQTT topic")
	}
	if err := validateNormalizedMessage(normalized); err != nil {
		return fmt.Errorf("validate MQTT message: %w", err)
	}
	if err := s.enrichNormalizedMessage(ctx, &normalized); err != nil {
		return fmt.Errorf("enrich MQTT message: %w", err)
	}
	if err := s.prepareNormalizedMessage(ctx, &normalized); err != nil {
		return fmt.Errorf("prepare MQTT message: %w", err)
	}

	mqttMsg := buildMessageModel(normalized)
	if err := s.SaveMessage(ctx, mqttMsg); err != nil {
		return fmt.Errorf("save MQTT message: %w", err)
	}

	return nil
}

// SaveMessage saves an incoming MQTT message to the database
func (s *MessageService) SaveMessage(ctx context.Context, msg *model.Message) error {
	return s.msgRepo.CreateWithNextSeq(ctx, msg)
}

// GetMessages returns messages for a conversation
func (s *MessageService) GetMessages(ctx context.Context, conversationID string, limit int, beforeSeq int64) ([]model.Message, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	messages, err := s.msgRepo.GetByConversationID(ctx, conversationID, limit, beforeSeq)
	if err != nil {
		return nil, err
	}
	return s.hydrateMessages(ctx, messages), nil
}

func (s *MessageService) GetMessagesAfterSeq(ctx context.Context, conversationID string, limit int, afterSeq int64) ([]model.Message, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	messages, err := s.msgRepo.GetByConversationIDAfterSeq(ctx, conversationID, limit, afterSeq)
	if err != nil {
		return nil, err
	}
	return s.hydrateMessages(ctx, messages), nil
}

// GetConversations returns a list of conversation IDs for a user
func (s *MessageService) GetConversations(ctx context.Context, userID uuid.UUID, limit int) ([]string, error) {
	if limit <= 0 {
		limit = 50
	}
	return s.msgRepo.GetConversations(ctx, userID, nil, limit)
}

func (s *MessageService) GetConversationsForBot(ctx context.Context, botID uuid.UUID, limit int) ([]string, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	return s.msgRepo.GetConversationsForBot(ctx, botID, limit)
}

func (s *MessageService) GetConversationListForBot(ctx context.Context, botID uuid.UUID, limit int) ([]ConversationInfo, error) {
	ids, err := s.GetConversationsForBot(ctx, botID, limit)
	if err != nil {
		return nil, err
	}

	result := make([]ConversationInfo, 0, len(ids))
	for _, id := range ids {
		msgs, queryErr := s.msgRepo.GetByConversationID(ctx, id, 1, 0)
		if queryErr != nil || len(msgs) == 0 {
			continue
		}

		result = append(result, ConversationInfo{
			ConversationID: id,
			LastMessage:    s.hydrateMessage(ctx, &msgs[0]),
			UnreadCount:    0,
		})
	}

	return result, nil
}

// ConversationInfo holds summary info for a conversation
type ConversationInfo struct {
	ConversationID string         `json:"conversation_id"`
	LastMessage    *model.Message `json:"last_message,omitempty"`
	UnreadCount    int64          `json:"unread_count"`
}

// GetConversationList returns conversation summaries for a user
func (s *MessageService) GetConversationList(ctx context.Context, userID uuid.UUID, limit int) ([]ConversationInfo, error) {
	ids, err := s.msgRepo.GetConversations(ctx, userID, nil, limit)
	if err != nil {
		return nil, err
	}
	result := make([]ConversationInfo, 0, len(ids))
	for _, id := range ids {
		msgs, err := s.msgRepo.GetByConversationID(ctx, id, 1, 0)
		if err != nil || len(msgs) == 0 {
			continue
		}
		result = append(result, ConversationInfo{
			ConversationID: id,
			LastMessage:    s.hydrateMessage(ctx, &msgs[0]),
			UnreadCount:    0,
		})
	}
	return result, nil
}

// MessagePayload represents an MQTT message payload
type MessagePayload struct {
	ID             string                 `json:"id"`
	MessageID      string                 `json:"message_id"`
	Topic          string                 `json:"topic,omitempty"`
	ConversationID string                 `json:"conversation_id,omitempty"`
	From           *MessagePeerPayload    `json:"from,omitempty"`
	To             *MessagePeerPayload    `json:"to,omitempty"`
	ContentRaw     json.RawMessage        `json:"content,omitempty"`
	Timestamp      int64                  `json:"timestamp"`
	Seq            int64                  `json:"seq,omitempty"`
	SenderType     string                 `json:"sender_type"`
	SenderID       string                 `json:"sender_id,omitempty"`
	SenderName     string                 `json:"sender_name,omitempty"`
	BotID          string                 `json:"bot_id,omitempty"`
	GroupID        string                 `json:"group_id,omitempty"`
	MsgType        string                 `json:"msg_type"`
	Body           string                 `json:"body,omitempty"`
	Metadata       map[string]interface{} `json:"metadata,omitempty"`
	Meta           map[string]interface{} `json:"meta,omitempty"`
}

type MessagePeerPayload struct {
	Type   string `json:"type"`
	ID     string `json:"id"`
	Name   string `json:"name,omitempty"`
	Avatar string `json:"avatar,omitempty"`
}

type MessageContentPayload struct {
	Type      string                 `json:"type"`
	Body      string                 `json:"body"`
	URL       string                 `json:"url,omitempty"`
	SourceURL string                 `json:"source_url,omitempty"`
	Meta      map[string]interface{} `json:"meta,omitempty"`
}

type normalizedMessage struct {
	messageID      string
	conversationID string
	senderType     string
	senderID       string
	senderName     string
	receiverType   string
	receiverID     string
	contentType    string
	body           string
	meta           map[string]interface{}
	timestamp      int64
	botID          string
	groupID        string
}

const mentionedBotIDsMetaKey = "mentioned_bot_ids"

func (s *MessageService) ListGroupsForBot(ctx context.Context, botID uuid.UUID) ([]model.Group, error) {
	return s.groupRepo.ListByBot(ctx, botID)
}

func NormalizeConversationReference(raw string) string {
	trimmed := strings.TrimSpace(strings.TrimPrefix(raw, "/"))
	if trimmed == "" {
		return ""
	}

	if decoded, err := url.PathUnescape(trimmed); err == nil && decoded != "" {
		trimmed = decoded
	}

	if strings.HasPrefix(trimmed, "chat/") {
		return trimmed
	}

	parts := strings.Split(trimmed, ":")
	if len(parts) == 3 {
		switch parts[0] {
		case "bot":
			return buildRealtimeConversationID("bot", parts[1], "bot", parts[2])
		case "group":
			return fmt.Sprintf("chat/group/%s", parts[2])
		case "user":
			return buildRealtimeConversationID("user", parts[1], "user", parts[2])
		}
	}

	return trimmed
}

func normalizeIncomingMessage(topic string, payload MessagePayload) normalizedMessage {
	conversationID := NormalizeConversationReference(firstNonEmpty(topic, payload.ConversationID, payload.Topic))
	route := parseMessageRoute(conversationID)
	normalized := normalizedMessage{
		messageID:      firstNonEmpty(payload.ID, payload.MessageID),
		conversationID: conversationID,
		senderType:     payload.SenderType,
		senderID:       payload.SenderID,
		senderName:     payload.SenderName,
		receiverType:   "",
		receiverID:     "",
		contentType:    firstNonEmpty(payload.MsgType, "text"),
		body:           payload.Body,
		meta:           firstNonEmptyMap(payload.Meta, payload.Metadata),
		timestamp:      payload.Timestamp,
		botID:          payload.BotID,
		groupID:        firstNonEmpty(payload.GroupID, route.groupID),
	}

	if payload.From != nil {
		normalized.senderType = firstNonEmpty(payload.From.Type, normalized.senderType)
		normalized.senderID = firstNonEmpty(payload.From.ID, normalized.senderID)
		normalized.senderName = firstNonEmpty(payload.From.Name, normalized.senderName)
	}
	if payload.To != nil {
		normalized.receiverType = firstNonEmpty(payload.To.Type, normalized.receiverType)
		normalized.receiverID = firstNonEmpty(payload.To.ID, normalized.receiverID)
	}
	if normalized.receiverType == "" || normalized.receiverID == "" {
		if counterpartType, counterpartID, ok := route.counterparty(normalized.senderType, normalized.senderID); ok {
			normalized.receiverType = counterpartType
			normalized.receiverID = counterpartID
		}
	}
	contentPayload, legacyText := decodeContentPayload(payload.ContentRaw)
	if contentPayload != nil {
		normalized.contentType = firstNonEmpty(contentPayload.Type, normalized.contentType)
		normalized.body = firstNonEmpty(contentPayload.Body, normalized.body)
		normalized.meta = withMessageContentAsset(firstNonEmptyMap(contentPayload.Meta, normalized.meta), contentPayload)
	}
	if normalized.body == "" {
		normalized.body = legacyText
	}
	normalized.body = normalizeMessageBody(normalized.contentType, normalized.body, normalized.meta)

	if normalized.messageID == "" {
		normalized.messageID = uuid.New().String()
	}
	if normalized.senderType == "" {
		normalized.senderType = string(model.SenderTypeSystem)
	}
	if normalized.contentType == "" {
		normalized.contentType = string(model.MsgTypeText)
	}
	if normalized.botID == "" {
		switch {
		case normalized.senderType == string(model.SenderTypeBot):
			normalized.botID = normalized.senderID
		case normalized.receiverType == "bot":
			normalized.botID = normalized.receiverID
		}
	}
	if normalized.groupID == "" && normalized.receiverType == "group" {
		normalized.groupID = normalized.receiverID
	}

	return normalized
}

func buildMessageModel(normalized normalizedMessage) *model.Message {
	msgID, err := uuid.Parse(normalized.messageID)
	if err != nil {
		msgID = uuid.New()
	}

	ts := time.Now()
	if normalized.timestamp > 0 {
		ts = normalizeUnixTimestamp(normalized.timestamp)
	}

	metadata := model.JSONMap(model.RemoveEphemeralAssetFields(normalized.meta))
	if metadata == nil {
		metadata = make(model.JSONMap)
	}

	return &model.Message{
		ConversationID: normalized.conversationID,
		MessageID:      msgID,
		SenderType:     model.SenderType(normalized.senderType),
		SenderID:       parseOptionalUUID(normalized.senderID),
		SenderName:     strPtrOrNil(normalized.senderName),
		BotID:          parseOptionalUUID(normalized.botID),
		GroupID:        parseOptionalUUID(normalized.groupID),
		MsgType:        model.MsgType(normalized.contentType),
		Content:        normalized.body,
		Metadata:       metadata,
		MQTTTopic:      normalized.conversationID,
		QOS:            1,
		Seq:            0,
		CreatedAt:      ts,
	}
}

func (s *MessageService) enrichNormalizedMessage(ctx context.Context, normalized *normalizedMessage) error {
	if normalized == nil || normalized.receiverType != "group" || normalized.receiverID == "" {
		return nil
	}

	groupID, ok := parseUUIDValue(normalized.receiverID)
	if !ok {
		return nil
	}

	botMembers, err := s.groupRepo.ListBotMembers(ctx, groupID)
	if err != nil {
		return err
	}

	mentionedBotIDs := mergeMentionedBotIDs(
		readMentionedBotIDsMeta(normalized.meta),
		extractMentionedBotIDs(normalized.body, botMembers),
	)
	if len(mentionedBotIDs) == 0 {
		if normalized.meta != nil {
			delete(normalized.meta, mentionedBotIDsMetaKey)
		}
		return nil
	}

	if normalized.meta == nil {
		normalized.meta = make(map[string]interface{}, 1)
	}
	normalized.meta[mentionedBotIDsMetaKey] = mentionedBotIDs
	return nil
}

func readMentionedBotIDsMeta(meta map[string]interface{}) []string {
	if len(meta) == 0 {
		return nil
	}

	raw, ok := meta[mentionedBotIDsMetaKey]
	if !ok {
		return nil
	}

	switch typed := raw.(type) {
	case []string:
		return append([]string(nil), typed...)
	case []interface{}:
		mentioned := make([]string, 0, len(typed))
		for _, item := range typed {
			if value, ok := item.(string); ok && strings.TrimSpace(value) != "" {
				mentioned = append(mentioned, strings.TrimSpace(value))
			}
		}
		return mentioned
	default:
		return nil
	}
}

func mergeMentionedBotIDs(groups ...[]string) []string {
	seen := make(map[string]struct{})
	merged := make([]string, 0)

	for _, items := range groups {
		for _, item := range items {
			value := strings.TrimSpace(item)
			if value == "" {
				continue
			}
			if _, exists := seen[value]; exists {
				continue
			}
			seen[value] = struct{}{}
			merged = append(merged, value)
		}
	}

	return merged
}

func (s *MessageService) prepareNormalizedMessage(ctx context.Context, normalized *normalizedMessage) error {
	if normalized == nil {
		return nil
	}
	if s.assetSvc == nil {
		return nil
	}

	resolvedMeta, err := s.assetSvc.ResolveMessageAsset(ctx, normalized.senderType, normalized.senderID, normalized.contentType, normalized.meta)
	if err != nil {
		return err
	}
	normalized.meta = resolvedMeta
	normalized.body = normalizeMessageBody(normalized.contentType, normalized.body, normalized.meta)
	return nil
}

func (s *MessageService) hydrateMessages(ctx context.Context, messages []model.Message) []model.Message {
	if len(messages) == 0 {
		return messages
	}

	hydrated := make([]model.Message, 0, len(messages))
	for index := range messages {
		hydrated = append(hydrated, *s.hydrateMessage(ctx, &messages[index]))
	}
	return hydrated
}

func (s *MessageService) hydrateMessage(ctx context.Context, message *model.Message) *model.Message {
	if message == nil || s.assetSvc == nil {
		return message
	}

	copy := *message
	meta := s.assetSvc.HydrateMessageAsset(ctx, copyMapFromJSON(copy.Metadata))
	copy.Metadata = model.JSONMap(meta)
	return &copy
}

func extractMentionedBotIDs(body string, botMembers []model.BotGroupMember) []string {
	body = strings.TrimSpace(body)
	if body == "" || len(botMembers) == 0 {
		return nil
	}

	aliasMap := make(map[string][]string)
	for _, member := range botMembers {
		botID := member.BotID.String()
		for _, alias := range candidateBotAliases(member) {
			aliasMap[alias] = append(aliasMap[alias], botID)
		}
	}

	type mentionAlias struct {
		alias string
		botID string
	}

	aliases := make([]mentionAlias, 0, len(aliasMap))
	for alias, botIDs := range aliasMap {
		if len(botIDs) != 1 {
			continue
		}
		aliases = append(aliases, mentionAlias{
			alias: alias,
			botID: botIDs[0],
		})
	}

	sort.Slice(aliases, func(i, j int) bool {
		if len(aliases[i].alias) == len(aliases[j].alias) {
			return aliases[i].alias < aliases[j].alias
		}
		return len(aliases[i].alias) > len(aliases[j].alias)
	})

	seen := make(map[string]struct{})
	mentioned := make([]string, 0, len(aliases))

	for index := 0; index < len(body); {
		r, size := utf8.DecodeRuneInString(body[index:])
		if r != '@' && r != '＠' {
			index += size
			continue
		}

		remaining := body[index+size:]
		matched := false
		for _, alias := range aliases {
			if !strings.HasPrefix(remaining, alias.alias) {
				continue
			}
			if !hasMentionBoundary(remaining[len(alias.alias):]) {
				continue
			}
			if _, exists := seen[alias.botID]; !exists {
				seen[alias.botID] = struct{}{}
				mentioned = append(mentioned, alias.botID)
			}
			index += size + len(alias.alias)
			matched = true
			break
		}

		if !matched {
			index += size
		}
	}

	return mentioned
}

func candidateBotAliases(member model.BotGroupMember) []string {
	aliases := []string{member.BotID.String()}
	if member.Nickname != nil {
		if alias := normalizeMentionAlias(*member.Nickname); alias != "" {
			aliases = append(aliases, alias)
		}
	}
	if member.Bot != nil {
		if alias := normalizeMentionAlias(member.Bot.Name); alias != "" {
			aliases = append(aliases, alias)
		}
	}
	return aliases
}

func normalizeMentionAlias(raw string) string {
	return strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(raw), "@"))
}

func hasMentionBoundary(remaining string) bool {
	if remaining == "" {
		return true
	}

	r, _ := utf8.DecodeRuneInString(remaining)
	return unicode.IsSpace(r) || unicode.IsPunct(r) || unicode.IsSymbol(r)
}

type messageRoute struct {
	leftType  string
	leftID    string
	rightType string
	rightID   string
	groupID   string
}

func parseMessageRoute(topic string) messageRoute {
	parts := splitMessageTopic(NormalizeConversationReference(topic))
	if len(parts) == 6 && parts[0] == "chat" && parts[1] == "dm" {
		return messageRoute{
			leftType:  parts[2],
			leftID:    parts[3],
			rightType: parts[4],
			rightID:   parts[5],
		}
	}
	if len(parts) == 3 && parts[0] == "chat" && parts[1] == "group" {
		return messageRoute{
			leftType:  "",
			leftID:    "",
			rightType: "",
			rightID:   "",
			groupID:   parts[2],
		}
	}
	return messageRoute{}
}

func buildRealtimeConversationID(senderType, senderID, receiverType, receiverID string) string {
	if receiverType == "group" {
		return fmt.Sprintf("chat/group/%s", receiverID)
	}

	leftType, leftID, rightType, rightID := canonicalizeDirectRoute(senderType, senderID, receiverType, receiverID)
	return fmt.Sprintf("chat/dm/%s/%s/%s/%s", leftType, leftID, rightType, rightID)
}

func parseOptionalUUID(raw string) *uuid.UUID {
	if raw == "" {
		return nil
	}
	parsed, err := uuid.Parse(raw)
	if err != nil {
		return nil
	}
	return &parsed
}

func normalizeUnixTimestamp(value int64) time.Time {
	if value <= 0 {
		return time.Now()
	}

	// Accept both Unix seconds and Unix milliseconds.
	if value >= 1_000_000_000_000 {
		return time.UnixMilli(value)
	}

	return time.Unix(value, 0)
}

func canonicalizeDirectRoute(leftType, leftID, rightType, rightID string) (string, string, string, string) {
	leftRank := directPeerRank(leftType)
	rightRank := directPeerRank(rightType)

	if leftRank != rightRank {
		if leftRank < rightRank {
			return leftType, leftID, rightType, rightID
		}
		return rightType, rightID, leftType, leftID
	}

	if leftID <= rightID {
		return leftType, leftID, rightType, rightID
	}

	return rightType, rightID, leftType, leftID
}

func directPeerRank(kind string) int {
	switch kind {
	case "user":
		return 0
	case "bot":
		return 1
	case "channel":
		return 2
	case "system":
		return 3
	default:
		return 4
	}
}

func (r messageRoute) isDirect() bool {
	return r.leftType != "" && r.leftID != "" && r.rightType != "" && r.rightID != ""
}

func (r messageRoute) hasParticipant(kind, id string) bool {
	return (r.leftType == kind && r.leftID == id) || (r.rightType == kind && r.rightID == id)
}

func (r messageRoute) counterparty(kind, id string) (string, string, bool) {
	switch {
	case r.leftType == kind && r.leftID == id:
		return r.rightType, r.rightID, r.rightType != "" && r.rightID != ""
	case r.rightType == kind && r.rightID == id:
		return r.leftType, r.leftID, r.leftType != "" && r.leftID != ""
	default:
		return "", "", false
	}
}

func (r messageRoute) matchesDirectedPair(senderType, senderID, receiverType, receiverID string) bool {
	if !r.isDirect() {
		return false
	}
	if senderType == receiverType && senderID == receiverID {
		return false
	}

	return r.hasParticipant(senderType, senderID) && r.hasParticipant(receiverType, receiverID)
}

func strPtrOrNil(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func firstNonEmptyMap(values ...map[string]interface{}) map[string]interface{} {
	for _, value := range values {
		if len(value) > 0 {
			return value
		}
	}
	return nil
}

func copyMapFromJSON(source model.JSONMap) map[string]interface{} {
	if source == nil {
		return nil
	}
	return model.CloneStringMap(source)
}

func splitMessageTopic(topic string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(topic); i++ {
		if topic[i] == '/' {
			parts = append(parts, topic[start:i])
			start = i + 1
		}
	}
	parts = append(parts, topic[start:])
	return parts
}

func decodeContentPayload(raw json.RawMessage) (*MessageContentPayload, string) {
	if len(raw) == 0 {
		return nil, ""
	}

	trimmed := strings.TrimSpace(string(raw))
	if trimmed == "" || trimmed == "null" {
		return nil, ""
	}

	if trimmed[0] == '{' {
		var payload MessageContentPayload
		if err := json.Unmarshal(raw, &payload); err == nil {
			return &payload, ""
		}
		return nil, ""
	}

	var legacyText string
	if err := json.Unmarshal(raw, &legacyText); err == nil {
		return nil, legacyText
	}

	return nil, ""
}

func withMessageContentAsset(meta map[string]interface{}, content *MessageContentPayload) map[string]interface{} {
	if content == nil {
		return meta
	}

	sourceURL := strings.TrimSpace(content.SourceURL)
	urlValue := strings.TrimSpace(content.URL)
	if sourceURL == "" && urlValue == "" {
		return meta
	}

	payload := model.AssetPayloadFromMap(meta)
	if payload == nil {
		payload = &model.AssetPayload{}
	}

	if payload.SourceURL == "" && sourceURL != "" {
		payload.SourceURL = sourceURL
	}
	if payload.DownloadURL == "" && payload.ExternalURL == "" && urlValue != "" && urlValue != payload.SourceURL {
		payload.ExternalURL = urlValue
	}

	return model.UpsertAssetPayload(meta, payload)
}

func normalizeMessageBody(contentType string, body string, meta map[string]interface{}) string {
	trimmed := strings.TrimSpace(body)
	if trimmed != "" || contentType == "" || contentType == string(model.MsgTypeText) {
		return trimmed
	}

	payload := model.AssetPayloadFromMap(meta)
	if payload == nil {
		return trimmed
	}
	if payload.FileName != "" {
		return payload.FileName
	}
	if contentType == string(model.MsgTypeImage) {
		return "Image"
	}
	return trimmed
}
