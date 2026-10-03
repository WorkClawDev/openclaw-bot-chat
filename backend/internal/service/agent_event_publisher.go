package service

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/openclaw-bot-chat/backend/internal/repository"
	"time"
)

func StartAgentEventPublisher(ctx context.Context, repo *repository.AgentRunRepository, publish func(string, []byte) error) {
	go func() {
		timer := time.NewTicker(250 * time.Millisecond)
		defer timer.Stop()
		for {
			rows, err := repo.PendingNotices(ctx)
			if err == nil {
				for _, row := range rows {
					payload, err := json.Marshal(row)
					if err != nil {
						continue
					}
					if err = publish(fmt.Sprintf("agent/user/%s/events", row.OwnerID), payload); err != nil {
						break
					}
					if err = repo.NoticeDelivered(ctx, row.ID); err != nil {
						break
					}
				}
			}
			select {
			case <-ctx.Done():
				return
			case <-timer.C:
			}
		}
	}()
}
