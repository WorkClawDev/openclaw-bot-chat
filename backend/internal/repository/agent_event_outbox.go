package repository

import (
	"context"
	"github.com/google/uuid"
)

type AgentEventNotice struct {
	ID      uuid.UUID `json:"id"`
	RunID   uuid.UUID `json:"run_id"`
	OwnerID uuid.UUID `json:"-"`
	Seq     int64     `json:"seq"`
	Type    string    `json:"type"`
}

func (r *AgentRunRepository) PendingNotices(ctx context.Context) ([]AgentEventNotice, error) {
	rows := []AgentEventNotice{}
	err := r.db.WithContext(ctx).Table("agent_run_events e").Select("e.id,e.run_id,r.owner_id,e.seq,e.type").Joins("JOIN agent_runs r ON r.id = e.run_id").Where("e.published = ?", false).Order("e.created_at ASC,e.seq ASC").Limit(200).Scan(&rows).Error
	return rows, err
}
func (r *AgentRunRepository) NoticeDelivered(ctx context.Context, id uuid.UUID) error {
	return r.db.WithContext(ctx).Table("agent_run_events").Where("id = ?", id).Update("published", true).Error
}
