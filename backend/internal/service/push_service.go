package service

import (
	"context"
	"time"

	"github.com/openclaw-bot-chat/backend/internal/repository"
	"github.com/openclaw-bot-chat/backend/pkg/apns"
)

type PushSender interface {
	Send(context.Context, apns.Notification) (apns.Result, error)
}
type PushService struct {
	Repo   *repository.PushRepository
	Sender PushSender
}

// DeliverNext uses a reclaimable lease. APNs acceptance is not device delivery;
// accepted records use that exact state instead of claiming the user saw them.
func (s *PushService) DeliverNext(ctx context.Context, now time.Time) (bool, error) {
	row, err := s.Repo.Claim(ctx, now)
	if err != nil || row == nil {
		return false, err
	}
	expires := row.CreatedAt.Add(24 * time.Hour)
	if !now.Before(expires) {
		return true, s.Repo.Finish(ctx, row, "expired", "Expired", now)
	}
	device, msg, err := s.Repo.Destination(ctx, row, now)
	if err != nil {
		return true, err
	} // lease expires after a transient DB failure.
	if device == nil {
		return true, s.Repo.Finish(ctx, row, "cancelled", "DestinationChanged", now)
	}
	result, sendErr := s.Sender.Send(ctx, apns.Notification{ID: row.ID.String(), DeviceToken: device.Token, Environment: device.Environment, UserID: row.UserID.String(), ConversationID: msg.ConversationID, MessageID: msg.MessageID.String(), Language: device.Language, ExpiresAt: expires})
	if sendErr != nil {
		result = apns.Result{Retry: true, Reason: "TransportUnavailable"}
	}
	if result.InvalidDevice {
		if err := s.Repo.Invalidate(ctx, device, result.InvalidSince); err != nil {
			return true, err
		}
	}
	state, next := "failed", now
	if result.Accepted {
		state = "accepted"
	} else if result.Retry && row.Attempts < 12 {
		state = "pending"
		delay := 15 * time.Second * time.Duration(1<<min(row.Attempts-1, 8))
		next = now.Add(delay)
	}
	return true, s.Repo.Finish(ctx, row, state, result.Reason, next)
}

func (s *PushService) Start(ctx context.Context, report func(error)) {
	go func() {
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		lastPrune := time.Time{}
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-ticker.C:
				for i := 0; i < 100 && ctx.Err() == nil; i++ {
					worked, err := s.DeliverNext(ctx, time.Now().UTC())
					if err != nil {
						report(err)
						break
					}
					if !worked {
						break
					}
				}
				if now.Sub(lastPrune) > time.Hour {
					if err := s.Repo.Prune(ctx, now); err != nil {
						report(err)
					}
					lastPrune = now
				}
			}
		}
	}()
}
