package handler

import (
	"fmt"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/middleware"
	"github.com/openclaw-bot-chat/backend/internal/service"
	apiresponse "github.com/openclaw-bot-chat/backend/pkg/response"
)

type RealtimeHandler struct {
	msgService *service.MessageService
	broker     config.BrokerClientConfig
}

const (
	botChatSlashCommandTopic                 = "control/bot-chat/slash-commands"
	botChatSlashAutocompleteRequestTopic     = "control/bot-chat/slash-autocomplete/request"
	botChatSlashAutocompleteResponseTopicFmt = "control/bot-chat/slash-autocomplete/response/user/%s"
)

type realtimeBootstrapResponse struct {
	Broker                         config.BrokerClientConfig `json:"broker"`
	ClientID                       string                    `json:"client_id"`
	PrincipalType                  string                    `json:"principal_type"`
	PrincipalID                    string                    `json:"principal_id"`
	Subscriptions                  []realtimeSubscription    `json:"subscriptions"`
	PublishTopics                  []string                  `json:"publish_topics"`
	SlashCommandTopic              string                    `json:"slash_command_topic,omitempty"`
	SlashAutocompleteRequestTopic  string                    `json:"slash_autocomplete_request_topic,omitempty"`
	SlashAutocompleteResponseTopic string                    `json:"slash_autocomplete_response_topic,omitempty"`
	History                        realtimeHistoryInfo       `json:"history"`
}

type realtimeSubscription struct {
	Topic string `json:"topic"`
	QOS   int    `json:"qos"`
}

type realtimeHistoryInfo struct {
	MaxCatchupBatch int `json:"max_catchup_batch"`
}

func NewRealtimeHandler(msgService *service.MessageService, mqttCfg config.MQTTConfig) *RealtimeHandler {
	return &RealtimeHandler{
		msgService: msgService,
		broker: config.BrokerClientConfig{
			TCPPublicURL: mqttCfg.TCPPublicURL,
			WSPublicURL:  mqttCfg.WSPublicURL,
			Username:     mqttCfg.Username,
			Password:     mqttCfg.Password,
			QOS:          int(mqttCfg.QOS),
		},
	}
}

func (h *RealtimeHandler) Bootstrap(c *gin.Context) {
	userID, ok := middleware.GetUserID(c)
	if !ok {
		apiresponse.Unauthorized(c, "unauthorized")
		return
	}

	topics, err := h.msgService.ListUserRealtimeTopics(c.Request.Context(), userID)
	if err != nil {
		apiresponse.InternalError(c, err.Error())
		return
	}
	responseTopic := fmt.Sprintf(botChatSlashAutocompleteResponseTopicFmt, userID.String())
	subscriptionTopics := service.UniqueTopicsForExport(append(topics, botChatSlashCommandTopic, responseTopic))
	publishTopics := service.UniqueTopicsForExport(append(topics, botChatSlashAutocompleteRequestTopic))

	apiresponse.Success(c, realtimeBootstrapResponse{
		Broker:                         h.broker,
		ClientID:                       fmt.Sprintf("frontend-%s-%s", userID.String(), uuid.NewString()[:8]),
		PrincipalType:                  "user",
		PrincipalID:                    userID.String(),
		Subscriptions:                  toRealtimeSubscriptions(subscriptionTopics, h.broker.QOS),
		PublishTopics:                  publishTopics,
		SlashCommandTopic:              botChatSlashCommandTopic,
		SlashAutocompleteRequestTopic:  botChatSlashAutocompleteRequestTopic,
		SlashAutocompleteResponseTopic: responseTopic,
		History: realtimeHistoryInfo{
			MaxCatchupBatch: 200,
		},
	})
}

func toRealtimeSubscriptions(topics []string, qos int) []realtimeSubscription {
	items := make([]realtimeSubscription, 0, len(topics))
	for _, topic := range topics {
		items = append(items, realtimeSubscription{
			Topic: topic,
			QOS:   qos,
		})
	}
	return items
}
