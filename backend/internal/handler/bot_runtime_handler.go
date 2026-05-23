package handler

import (
	"errors"
	"fmt"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	responsedto "github.com/openclaw-bot-chat/backend/internal/model/response"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

type BotRuntimeHandler struct {
	msgService *service.MessageService
	assetSvc   *service.AssetService
	broker     config.BrokerClientConfig
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

func (h *BotRuntimeHandler) ImportImage(c *gin.Context) {
	bot, ok := middleware.GetBot(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}
	if h.assetSvc == nil {
		apiresponse.InternalError(c, "asset service unavailable")
		return
	}

	var req service.ImportBotImageRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		apiresponse.BadRequest(c, "invalid request: "+err.Error())
		return
	}

	asset, err := h.assetSvc.ImportImageForBot(c.Request.Context(), bot.ID, req)
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
