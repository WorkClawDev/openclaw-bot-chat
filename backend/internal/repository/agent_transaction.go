package repository

import (
	"context"
	"gorm.io/gorm"
)

type agentTransactionKey struct{}

func WithAgentTransaction(ctx context.Context, tx *gorm.DB) context.Context {
	return context.WithValue(ctx, agentTransactionKey{}, tx)
}
func agentDB(ctx context.Context, fallback *gorm.DB) *gorm.DB {
	if tx, ok := ctx.Value(agentTransactionKey{}).(*gorm.DB); ok {
		return tx.WithContext(ctx)
	}
	return fallback.WithContext(ctx)
}
