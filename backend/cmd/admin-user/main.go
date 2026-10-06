// admin-user promotes an existing active account using operator database access.
// Registration never grants administrator privileges, including the first user.
package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/google/uuid"
	"github.com/openclaw-bot-chat/backend/internal/config"
	"github.com/openclaw-bot-chat/backend/internal/model"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
)

func main() {
	username := flag.String("username", "", "existing active account to promote")
	configPath := flag.String("config", "config.yaml", "backend configuration file")
	flag.Parse()
	if *username == "" {
		fmt.Fprintln(os.Stderr, "-username is required")
		os.Exit(2)
	}
	cfg, err := config.Load(*configPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "could not load backend configuration")
		os.Exit(1)
	}
	db, err := gorm.Open(postgres.Open(cfg.Database.DSN()), &gorm.Config{})
	if err != nil {
		fmt.Fprintln(os.Stderr, "could not connect to database")
		os.Exit(1)
	}
	err = db.Transaction(func(tx *gorm.DB) error {
		var user model.User
		if err := tx.First(&user, "username = ?", *username).Error; err != nil {
			return err
		}
		if !user.IsActive() {
			return fmt.Errorf("account must be active")
		}
		if err := tx.Model(&user).Update("role", model.UserRoleAdmin).Error; err != nil {
			return err
		}
		return tx.Create(&model.AuditLog{EventID: uuid.New(), UserID: &user.ID, ResourceID: &user.ID, Action: "bootstrap_administrator"}).Error
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "promotion failed; ensure the account exists and migrations have run")
		os.Exit(1)
	}
	fmt.Println("Administrator role granted to the selected account.")
}
