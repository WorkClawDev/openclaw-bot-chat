package service

import (
	"context"
	"errors"
	"fmt"
	"sort"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
)

var (
	ErrConversationAccessDenied = errors.New("you do not have access to this conversation")
	ErrInvalidMessageRoute      = errors.New("invalid message route")
	ErrGroupAdminRequired       = errors.New("only group owner or admin can add members")
)

func (s *MessageService) CanUserAccessConversation(ctx context.Context, userID uuid.UUID, conversationID string) error {
	route := parseMessageRoute(conversationID)

	switch {
	case route.groupID != "":
		groupID, ok := parseUUIDValue(route.groupID)
		if !ok {
			return ErrInvalidMessageRoute
		}
		allowed, err := s.isUserGroupMember(ctx, userID, groupID)
		if err != nil {
			return err
		}
		if !allowed {
			return ErrConversationAccessDenied
		}
		return nil
	case !route.isDirect():
		return ErrInvalidMessageRoute
	default:
		allowed, err := s.userMatchesDirectRoute(ctx, userID, route)
		if err != nil {
			return err
		}
		if !allowed {
			return ErrConversationAccessDenied
		}
		return nil
	}
}

func (s *MessageService) CanBotAccessConversation(ctx context.Context, botID uuid.UUID, conversationID string) error {
	route := parseMessageRoute(conversationID)

	switch {
	case route.groupID != "":
		groupID, ok := parseUUIDValue(route.groupID)
		if !ok {
			return ErrInvalidMessageRoute
		}
		allowed, err := s.isBotGroupMember(ctx, groupID, botID)
		if err != nil {
			return err
		}
		if !allowed {
			return ErrConversationAccessDenied
		}
		return nil
	case !route.isDirect():
		return ErrInvalidMessageRoute
	case route.hasParticipant("bot", botID.String()):
		return nil
	default:
		return ErrConversationAccessDenied
	}
}

func (s *MessageService) ListUserRealtimeTopics(ctx context.Context, userID uuid.UUID) ([]string, error) {
	topics := make([]string, 0, 32)

	conversations, err := s.GetConversations(ctx, userID, 200)
	if err != nil {
		return nil, err
	}
	topics = append(topics, conversations...)

	// A new bot has no message history yet, but its owner must be able to
	// subscribe and publish the first DM using scoped broker credentials.
	const pageSize = 500
	for page := 1; ; page++ {
		bots, total, err := s.botRepo.ListByOwner(ctx, userID, page, pageSize)
		if err != nil {
			return nil, err
		}
		for _, bot := range bots {
			if bot.Status == model.BotStatusEnabled {
				topics = append(topics, fmt.Sprintf("%s/dm/user/%s/bot/%s", messageTopicPrefix, userID, bot.ID))
			}
		}
		if len(bots) == 0 || int64(page*pageSize) >= total {
			break
		}
	}

	groups, _, err := s.groupRepo.ListByUser(ctx, userID, 1, 500)
	if err != nil {
		return nil, err
	}
	for _, group := range groups {
		if !group.IsActive {
			continue
		}
		topics = append(topics, fmt.Sprintf("%s/group/%s", messageTopicPrefix, group.ID.String()))
	}

	return uniqueSortedTopics(topics), nil
}

func (s *MessageService) ListBotRealtimeTopics(ctx context.Context, botID uuid.UUID) ([]string, error) {
	topics := make([]string, 0, 32)
	botIDString := botID.String()
	topics = append(topics,
		fmt.Sprintf("%s/dm/user/+/bot/%s", messageTopicPrefix, botIDString),
		fmt.Sprintf("%s/dm/bot/%s/bot/+", messageTopicPrefix, botIDString),
		fmt.Sprintf("%s/dm/bot/+/bot/%s", messageTopicPrefix, botIDString),
	)

	conversations, err := s.GetConversationsForBot(ctx, botID, 200)
	if err != nil {
		return nil, err
	}
	for _, conversation := range conversations {
		if parseMessageRoute(conversation).isDirect() {
			continue
		}
		topics = append(topics, conversation)
	}

	groups, err := s.ListGroupsForBot(ctx, botID)
	if err != nil {
		return nil, err
	}
	for _, group := range groups {
		if !group.IsActive {
			continue
		}
		topics = append(topics, fmt.Sprintf("%s/group/%s", messageTopicPrefix, group.ID.String()))
	}

	return uniqueSortedTopics(topics), nil
}

func (s *MessageService) userMatchesDirectRoute(ctx context.Context, userID uuid.UUID, route messageRoute) (bool, error) {
	if route.hasParticipant("user", userID.String()) {
		return true, nil
	}

	for _, candidate := range []struct {
		kind string
		id   string
	}{
		{kind: route.leftType, id: route.leftID},
		{kind: route.rightType, id: route.rightID},
	} {
		if candidate.kind != "bot" {
			continue
		}
		botID, ok := parseUUIDValue(candidate.id)
		if !ok {
			continue
		}
		ownsBot, err := s.userOwnsBot(ctx, userID, botID)
		if err != nil {
			return false, err
		}
		if ownsBot {
			return true, nil
		}
	}

	return false, nil
}

func (s *MessageService) userOwnsBot(ctx context.Context, userID, botID uuid.UUID) (bool, error) {
	bot, err := s.botRepo.GetByID(ctx, botID)
	if err != nil {
		return false, nil
	}
	return bot.OwnerID == userID, nil
}

func (s *MessageService) isUserGroupMember(ctx context.Context, userID, groupID uuid.UUID) (bool, error) {
	group, err := s.groupRepo.GetByID(ctx, groupID)
	if err != nil {
		return false, nil
	}
	if !group.IsActive || group.OwnerID == userID {
		return group.IsActive, nil
	}
	return s.groupRepo.IsMember(ctx, groupID, userID)
}

func (s *MessageService) isBotGroupMember(ctx context.Context, groupID, botID uuid.UUID) (bool, error) {
	group, err := s.groupRepo.GetByID(ctx, groupID)
	if err != nil {
		return false, nil
	}
	if !group.IsActive {
		return false, nil
	}
	return s.groupRepo.IsBotMember(ctx, groupID, botID)
}

func validateNormalizedMessage(normalized normalizedMessage) error {
	if normalized.body == "" {
		return errors.New("message body is required")
	}

	route := parseMessageRoute(normalized.conversationID)
	switch {
	case route.groupID != "":
		if normalized.receiverType != "group" || normalized.receiverID != route.groupID {
			return ErrInvalidMessageRoute
		}
	case !route.isDirect():
		return ErrInvalidMessageRoute
	case !route.matchesDirectedPair(
		normalized.senderType,
		normalized.senderID,
		normalized.receiverType,
		normalized.receiverID,
	):
		return ErrInvalidMessageRoute
	}

	return nil
}

func parseUUIDValue(raw string) (uuid.UUID, bool) {
	parsed, err := uuid.Parse(raw)
	if err != nil {
		return uuid.UUID{}, false
	}
	return parsed, true
}

const messageTopicPrefix = "chat"

func uniqueSortedTopics(topics []string) []string {
	if len(topics) == 0 {
		return []string{}
	}

	set := make(map[string]struct{}, len(topics))
	unique := make([]string, 0, len(topics))
	for _, topic := range topics {
		topic = NormalizeConversationReference(topic)
		if topic == "" {
			continue
		}
		if _, exists := set[topic]; exists {
			continue
		}
		set[topic] = struct{}{}
		unique = append(unique, topic)
	}

	sort.Strings(unique)
	return unique
}

func UniqueTopicsForExport(topics []string) []string {
	return uniqueSortedTopics(topics)
}
