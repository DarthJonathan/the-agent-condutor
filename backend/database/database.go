package database

import (
	"agent-conductor/backend/dao"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func Open(dsn string) (*gorm.DB, error) {
	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		return nil, err
	}
	sql, err := db.DB()
	if err != nil {
		return nil, err
	}
	sql.SetMaxOpenConns(16)
	sql.SetMaxIdleConns(4)
	err = db.AutoMigrate(&dao.User{}, &dao.Session{}, &dao.Device{}, &dao.Workspace{}, &dao.Snapshot{}, &dao.Event{}, &dao.Command{})
	return db, err
}
