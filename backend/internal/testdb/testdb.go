// Package testdb creates a disposable schema, never touching the application's tables.
package testdb

import (
	"agent-conductor/backend/database"
	"agent-conductor/backend/service"
	"net/url"
	"os"
	"strings"
	"testing"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func Open(t *testing.T) *gorm.DB {
	t.Helper()
	dsn := os.Getenv("CONDUCTOR_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("set CONDUCTOR_TEST_DATABASE_URL for PostgreSQL integration tests")
	}
	base, err := gorm.Open(postgres.Open(dsn), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
	if err != nil {
		t.Fatal("test database connection failed:", err)
	}
	schema := "conductor_test_" + strings.ReplaceAll(service.ID(), "-", "")
	if err := base.Exec(`CREATE SCHEMA "` + schema + `"`).Error; err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(dsn)
	if err != nil || (u.Scheme != "postgres" && u.Scheme != "postgresql") {
		t.Fatal("test DSN must be a PostgreSQL URL")
	}
	query := u.Query()
	query.Set("search_path", schema)
	u.RawQuery = query.Encode()
	db, err := database.Open(u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if pool, err := db.DB(); err == nil {
			_ = pool.Close()
		}
		if err := base.Exec(`DROP SCHEMA "` + schema + `" CASCADE`).Error; err != nil {
			t.Error(err)
		}
		if pool, err := base.DB(); err == nil {
			_ = pool.Close()
		}
	})
	return db
}
