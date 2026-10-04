package repository

import (
	"context"
	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"time"
)

func (r *AgentRunRepository) Health(ctx context.Context, owner uuid.UUID) (map[string]interface{}, error) {
	db := r.db.WithContext(ctx)
	counts := map[string]int64{}
	for _, status := range []string{"queued", "running", "waiting_input", "waiting_approval", "paused", "succeeded", "failed", "cancelled"} {
		var n int64
		if err := db.Model(&model.AgentRun{}).Where("owner_id = ? AND status = ?", owner, status).Count(&n).Error; err != nil {
			return nil, err
		}
		counts[status] = n
	}
	var expired, inbox, events, uncertain, steps int64
	if err := db.Model(&model.AgentRun{}).Where("owner_id = ? AND status = 'running' AND lease_until <= ?", owner, time.Now().UnixMilli()).Count(&expired).Error; err != nil {
		return nil, err
	}
	if err := db.Model(&model.AgentInbox{}).Where("owner_id = ? AND delivered = ?", owner, false).Count(&inbox).Error; err != nil {
		return nil, err
	}
	if err := db.Table("agent_run_events e").Joins("JOIN agent_runs r ON r.id = e.run_id").Where("r.owner_id = ? AND e.published = ?", owner, false).Count(&events).Error; err != nil {
		return nil, err
	}
	if err := db.Table("agent_tool_calls t").Joins("JOIN agent_runs r ON CAST(r.id AS TEXT) = t.run_id").Where("t.owner_id = ? AND t.idempotent = ? AND t.status IN ? AND r.lease_until = 0 AND r.status IN ?", owner, false, []string{"started", "uncertain"}, []string{"waiting_input", "paused", "failed"}).Count(&uncertain).Error; err != nil {
		return nil, err
	}
	if err := db.Model(&model.AgentRun{}).Where("owner_id = ?", owner).Select("COALESCE(SUM(steps),0)").Scan(&steps).Error; err != nil {
		return nil, err
	}
	return map[string]interface{}{"run_counts": counts, "expired_running_leases": expired, "undelivered_inbox": inbox, "pending_event_notices": events, "tools_requiring_reconciliation": uncertain, "executed_steps": steps, "at": time.Now().UTC()}, nil
}
