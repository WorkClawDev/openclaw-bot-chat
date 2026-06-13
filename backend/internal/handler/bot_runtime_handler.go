package handler

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/model"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

type BotRuntimeHandler struct {
	msgService  *service.MessageService
	assetSvc    *service.AssetService
	documentSvc *service.DocumentService
	broker      config.BrokerClientConfig
}

type botRuntimeBootstrapResponse struct {
	Bot                           botRuntimeBotInfo         `json:"bot"`
	Broker                        config.BrokerClientConfig `json:"broker"`
	ClientID                      string                    `json:"client_id"`
	Groups                        []botRuntimeGroupInfo     `json:"groups"`
	Conversations                 []botRuntimeDialogInfo    `json:"conversations"`
	Subscriptions                 []realtimeSubscription    `json:"subscriptions"`
	PublishTopics                 []string                  `json:"publish_topics"`
	SlashCommandTopic             string                    `json:"slash_command_topic,omitempty"`
	SlashAutocompleteRequestTopic string                    `json:"slash_autocomplete_request_topic,omitempty"`
	History                       realtimeHistoryInfo       `json:"history"`
}

type botRuntimeBotInfo struct {
	ID          string                 `json:"id"`
	Name        string                 `json:"name,omitempty"`
	Description *string                `json:"description,omitempty"`
	Status      string                 `json:"status,omitempty"`
	Config      map[string]interface{} `json:"config,omitempty"`
}

type botRuntimeGroupInfo struct {
	ID    string `json:"id"`
	Name  string `json:"name,omitempty"`
	Topic string `json:"topic,omitempty"`
}

type botRuntimeDialogInfo struct {
	ConversationID string `json:"conversation_id"`
	Topic          string `json:"topic,omitempty"`
	LastSeq        int64  `json:"last_seq,omitempty"`
	LastMessageID  string `json:"last_message_id,omitempty"`
	UpdatedAt      int64  `json:"updated_at,omitempty"`
}

func NewBotRuntimeHandler(
	msgService *service.MessageService,
	assetSvc *service.AssetService,
	mqttCfg config.MQTTConfig,
) *BotRuntimeHandler {
	return &BotRuntimeHandler{
		msgService: msgService,
		assetSvc:   assetSvc,
		broker: config.BrokerClientConfig{
			TCPPublicURL: mqttCfg.TCPPublicURL,
			WSPublicURL:  mqttCfg.WSPublicURL,
			Username:     mqttCfg.Username,
			Password:     mqttCfg.Password,
			QOS:          int(mqttCfg.QOS),
		},
	}
}

func (h *BotRuntimeHandler) SetDocumentService(documentSvc *service.DocumentService) {
	h.documentSvc = documentSvc
}

func (h *BotRuntimeHandler) Bootstrap(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	groups, err := h.msgService.ListGroupsForBot(c.Request.Context(), bot.ID)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}

	conversations, err := h.msgService.GetConversationListForBot(c.Request.Context(), bot.ID, 200)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}

	subscriptionTopics, err := h.msgService.ListBotRealtimeTopics(c.Request.Context(), bot.ID)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}

	groupInfos := make([]botRuntimeGroupInfo, 0, len(groups))
	publishTopics := make([]string, 0, len(conversations)+len(groups))
	for _, group := range groups {
		topic := service.NormalizeConversationReference(fmt.Sprintf("chat/group/%s", group.ID.String()))
		groupInfos = append(groupInfos, botRuntimeGroupInfo{
			ID:    group.ID.String(),
			Name:  group.Name,
			Topic: topic,
		})
		publishTopics = append(publishTopics, topic)
	}

	dialogs := make([]botRuntimeDialogInfo, 0, len(conversations))
	for _, conversation := range conversations {
		dialog := botRuntimeDialogInfo{
			ConversationID: conversation.ConversationID,
			Topic:          conversation.ConversationID,
		}
		if conversation.LastMessage != nil {
			dialog.LastSeq = conversation.LastMessage.Seq
			dialog.LastMessageID = conversation.LastMessage.MessageID.String()
			dialog.UpdatedAt = conversation.LastMessage.CreatedAt.Unix()
		}
		dialogs = append(dialogs, dialog)
		publishTopics = append(publishTopics, conversation.ConversationID)
	}

	status := ""
	if response := responsedto.NewBotResponse(bot); response != nil {
		status = response.Status
	}

	apiresponse.Success(c, botRuntimeBootstrapResponse{
		Bot: botRuntimeBotInfo{
			ID:          bot.ID.String(),
			Name:        bot.Name,
			Description: bot.Description,
			Status:      status,
			Config:      copyBotRuntimeMap(map[string]interface{}(bot.Config)),
		},
		Broker:        h.broker,
		ClientID:      fmt.Sprintf("bot-%s-%s", bot.ID.String(), uuid.NewString()[:8]),
		Groups:        groupInfos,
		Conversations: dialogs,
		Subscriptions: toRealtimeSubscriptions(
			service.UniqueTopicsForExport(append(subscriptionTopics, botChatSlashAutocompleteRequestTopic)),
			h.broker.QOS,
		),
		PublishTopics:                 service.UniqueTopicsForExport(append(publishTopics, botChatSlashCommandTopic)),
		SlashCommandTopic:             botChatSlashCommandTopic,
		SlashAutocompleteRequestTopic: botChatSlashAutocompleteRequestTopic,
		History: realtimeHistoryInfo{
			MaxCatchupBatch: 200,
		},
	})
}

func (h *BotRuntimeHandler) CreateDocument(c *gin.Context) {
	h.createDocument(c, false)
}

type botRuntimeCreateDocumentRequest struct {
	service.CreateDocumentRequest
	SendURL *bool `json:"send_url"`
}

type botRuntimeCreateDocumentResponse struct {
	Document *responsedto.DocumentResponse `json:"document"`
	Message  *responsedto.MessageResponse  `json:"message,omitempty"`
}

type botRuntimeUpdateDocumentResponse struct {
	Document *responsedto.DocumentResponse `json:"document"`
	Message  *responsedto.MessageResponse  `json:"message,omitempty"`
}

type botRuntimeUpdateDocumentRequest struct {
	service.UpdateDocumentRequest
	ConversationID string `json:"conversation_id"`
	SendURL        *bool  `json:"send_url"`
}

func (h *BotRuntimeHandler) createDocument(c *gin.Context, forceURL bool) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	if h.documentSvc == nil {
		apiresponse.InternalError(c, "document service unavailable")
		return
	}

	var req botRuntimeCreateDocumentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	conversationID := service.NormalizeConversationReference(req.CreateDocumentRequest.ConversationID)
	shouldSendURL := forceURL || (req.SendURL != nil && *req.SendURL)
	if shouldSendURL && conversationID == "" {
		apiresponse.BadRequest(c, "conversation_id is required to send a document url")
		return
	}
	if conversationID != "" {
		if err := h.msgService.CanBotAccessConversation(c.Request.Context(), bot.ID, conversationID); err != nil {
			writeBotRuntimeConversationError(c, err)
			return
		}
		req.CreateDocumentRequest.ConversationID = conversationID
	}
	ownerID := documentOwnerForBotRequest(bot.OwnerID, bot.ID, conversationID)

	document, err := h.documentSvc.CreateFromBot(c.Request.Context(), ownerID, bot.ID, req.CreateDocumentRequest)
	if err != nil {
		writeDocumentError(c, err)
		return
	}

	var message *model.Message
	if shouldSendURL {
		message = buildBotDocumentURLMessage(bot, conversationID, document)
		if err := h.msgService.SaveMessage(c.Request.Context(), message); err != nil {
			apiresponse.InternalError(c, err.Error())
			return
		}
		updatedDocument, err := h.documentSvc.SetSourceMessage(c.Request.Context(), ownerID, document.ID, message.MessageID)
		if err == nil {
			document = updatedDocument
		} else {
			// Non-fatal for card delivery; document ownership and card metadata are already valid.
		}
	}

	apiresponse.Created(c, botRuntimeCreateDocumentResponse{
		Document: responsedto.NewDocumentResponse(document, true),
		Message:  responsedto.NewMessageResponse(message),
	})
}

func (h *BotRuntimeHandler) UpdateDocument(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	if h.documentSvc == nil {
		apiresponse.InternalError(c, "document service unavailable")
		return
	}
	documentID, err := uuid.Parse(c.Param("id"))
	if err != nil {
		apiresponse.BadRequest(c, "invalid document id")
		return
	}
	var req botRuntimeUpdateDocumentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}
	conversationID := service.NormalizeConversationReference(req.ConversationID)
	shouldSendURL := req.SendURL != nil && *req.SendURL
	if shouldSendURL && conversationID == "" {
		apiresponse.BadRequest(c, "conversation_id is required to send a document url")
		return
	}
	if conversationID != "" {
		if err := h.msgService.CanBotAccessConversation(c.Request.Context(), bot.ID, conversationID); err != nil {
			writeBotRuntimeConversationError(c, err)
			return
		}
	}
	document, err := h.documentSvc.UpdateFromBot(c.Request.Context(), bot.OwnerID, bot.ID, documentID, req.UpdateDocumentRequest)
	if err != nil {
		writeDocumentError(c, err)
		return
	}
	var message *model.Message
	if shouldSendURL {
		message = buildBotDocumentURLMessage(bot, conversationID, document)
		message.Content = fmt.Sprintf("文档已更新：[%s](%s)", document.Title, responsedto.DocumentURL(document.ID))
		if err := h.msgService.SaveMessage(c.Request.Context(), message); err != nil {
			apiresponse.InternalError(c, err.Error())
			return
		}
		updatedDocument, err := h.documentSvc.SetSourceMessage(c.Request.Context(), bot.OwnerID, document.ID, message.MessageID)
		if err == nil {
			document = updatedDocument
		}
	}
	apiresponse.Success(c, botRuntimeUpdateDocumentResponse{
		Document: responsedto.NewDocumentResponse(document, true),
		Message:  responsedto.NewMessageResponse(message),
	})
}

func documentOwnerForBotRequest(botOwnerID uuid.UUID, botID uuid.UUID, conversationID string) uuid.UUID {
	parts := strings.Split(strings.Trim(conversationID, "/"), "/")
	if len(parts) == 6 && parts[0] == "chat" && parts[1] == "dm" {
		leftType, leftID := parts[2], parts[3]
		rightType, rightID := parts[4], parts[5]
		if leftType == "user" && rightType == "bot" && strings.EqualFold(rightID, botID.String()) {
			if parsed, err := uuid.Parse(leftID); err == nil && parsed == botOwnerID {
				return parsed
			}
		}
		if rightType == "user" && leftType == "bot" && strings.EqualFold(leftID, botID.String()) {
			if parsed, err := uuid.Parse(rightID); err == nil && parsed == botOwnerID {
				return parsed
			}
		}
	}
	return botOwnerID
}

func buildBotDocumentURLMessage(bot *model.Bot, conversationID string, document *model.Document) *model.Message {
	messageID := uuid.New()
	botName := bot.Name
	documentURL := responsedto.DocumentURL(document.ID)
	meta := model.JSONMap{
		"document_id":         document.ID.String(),
		"document_url":        documentURL,
		"document_title":      document.Title,
		"document_summary":    document.Summary,
		"document_type":       string(document.DocumentType),
		"document_source":     string(document.Source),
		"document_updated_at": document.UpdatedAt,
	}
	return &model.Message{
		ConversationID: conversationID,
		MessageID:      messageID,
		SenderType:     model.SenderTypeBot,
		SenderID:       &bot.ID,
		SenderName:     &botName,
		BotID:          &bot.ID,
		MsgType:        model.MsgTypeText,
		Content:        fmt.Sprintf("文档已创建：[%s](%s)", document.Title, documentURL),
		Metadata:       meta,
		MQTTTopic:      conversationID,
		QOS:            1,
		CreatedAt:      time.Now(),
	}
}

func writeBotRuntimeConversationError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, service.ErrConversationAccessDenied):
		apiresponse.Forbidden(c, err.Error())
	case errors.Is(err, service.ErrInvalidMessageRoute):
		apiresponse.BadRequest(c, err.Error())
	default:
		apiresponse.InternalError(c, err.Error())
	}
}

func (h *BotRuntimeHandler) ImportImage(c *gin.Context) {
	h.importAsset(c, "image")
}

func (h *BotRuntimeHandler) ImportAudio(c *gin.Context) {
	h.importAsset(c, "audio")
}

func (h *BotRuntimeHandler) importAsset(c *gin.Context, kind string) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	if h.assetSvc == nil {
		apiresponse.InternalError(c, "asset service unavailable")
		return
	}

	if strings.HasPrefix(c.ContentType(), "multipart/form-data") {
		h.importAssetMultipart(c, bot.ID, kind)
		return
	}

	var req service.ImportBotImageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	var asset *model.AssetPayload
	var err error
	switch kind {
	case "audio":
		asset, err = h.assetSvc.ImportAudioForBot(c.Request.Context(), bot.ID, req)
	default:
		asset, err = h.assetSvc.ImportImageForBot(c.Request.Context(), bot.ID, req)
	}
	if err != nil {
		switch {
		case errors.Is(err, service.ErrAssetProviderDisabled),
			errors.Is(err, service.ErrAssetTooLarge),
			errors.Is(err, service.ErrAssetUnsupportedType),
			errors.Is(err, service.ErrAssetInvalid):
			apiresponse.BadRequest(c, err.Error())
		default:
			apiresponse.InternalError(c, err.Error())
		}
		return
	}

	apiresponse.Success(c, responsedto.NewAssetResponse(asset))
}

func (h *BotRuntimeHandler) importAssetMultipart(c *gin.Context, botID uuid.UUID, kind string) {
	fileHeader, err := c.FormFile("file")
	if err != nil {
		apiresponse.BadRequest(c, "file is required")
		return
	}
	file, err := fileHeader.Open()
	if err != nil {
		apiresponse.BadRequest(c, "invalid file upload")
		return
	}
	defer file.Close()

	payload, err := io.ReadAll(file)
	if err != nil {
		apiresponse.BadRequest(c, "failed to read file upload")
		return
	}
	contentType := strings.TrimSpace(c.PostForm("content_type"))
	if contentType == "" {
		contentType = strings.TrimSpace(fileHeader.Header.Get("Content-Type"))
	}
	if contentType == "" {
		contentType = http.DetectContentType(payload)
	}
	fileName := strings.TrimSpace(c.PostForm("file_name"))
	if fileName == "" {
		fileName = fileHeader.Filename
	}

	var asset *model.AssetPayload
	switch kind {
	case "audio":
		asset, err = h.assetSvc.ImportAudioBytesForBot(c.Request.Context(), botID, payload, fileName, contentType)
	default:
		asset, err = h.assetSvc.ImportImageBytesForBot(c.Request.Context(), botID, payload, fileName, contentType)
	}
	if err != nil {
		switch {
		case errors.Is(err, service.ErrAssetProviderDisabled),
			errors.Is(err, service.ErrAssetTooLarge),
			errors.Is(err, service.ErrAssetUnsupportedType),
			errors.Is(err, service.ErrAssetInvalid):
			apiresponse.BadRequest(c, err.Error())
		default:
			apiresponse.InternalError(c, err.Error())
		}
		return
	}

	apiresponse.Success(c, responsedto.NewAssetResponse(asset))
}

func (h *BotRuntimeHandler) GetConversationMessages(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	conversationID := service.NormalizeConversationReference(c.Param("conversation_id"))
	if conversationID == "" {
		apiresponse.BadRequest(c, "conversation_id is required")
		return
	}

	if err := h.msgService.CanBotAccessConversation(c.Request.Context(), bot.ID, conversationID); err != nil {
		switch {
		case errors.Is(err, service.ErrConversationAccessDenied):
			apiresponse.Forbidden(c, err.Error())
		case errors.Is(err, service.ErrInvalidMessageRoute):
			apiresponse.BadRequest(c, err.Error())
		default:
			apiresponse.InternalError(c, err.Error())
		}
		return
	}

	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	if limit < 1 || limit > 200 {
		limit = 50
	}
	afterSeq, _ := strconv.ParseInt(c.DefaultQuery("after_seq", "0"), 10, 64)

	var (
		messages interface{}
		err      error
	)
	if afterSeq > 0 {
		rawMessages, queryErr := h.msgService.GetMessagesAfterSeq(c.Request.Context(), conversationID, limit, afterSeq)
		err = queryErr
		messages = responsedto.NewMessageResponses(rawMessages)
	} else {
		rawMessages, queryErr := h.msgService.GetMessages(c.Request.Context(), conversationID, limit, 0)
		err = queryErr
		messages = responsedto.NewMessageResponses(rawMessages)
	}
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}

	apiresponse.Success(c, gin.H{"messages": messages})
}

func copyBotRuntimeMap(source map[string]interface{}) map[string]interface{} {
	if source == nil {
		return nil
	}

	copied := make(map[string]interface{}, len(source))
	for key, value := range source {
		copied[key] = value
	}
	return copied
}
