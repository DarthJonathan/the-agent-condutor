package service

import (
	"agent-conductor/backend/dao"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"github.com/hashicorp/go-uuid"
	"golang.org/x/crypto/bcrypt"
	"gorm.io/gorm"
	"gorm.io/gorm/clause"
	"net/mail"
	"strings"
	"time"
)

func ID() string {
	v, err := uuid.GenerateUUID()
	if err != nil {
		panic(err)
	}
	return v
}
func ValidID(v string) bool { parsed, err := uuid.ParseUUID(v); return err == nil && len(parsed) == 16 }
func Token() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func Hash(v string) string { h := sha256.Sum256([]byte(v)); return hex.EncodeToString(h[:]) }
func CSRF(secret, token string) string {
	h := hmac.New(sha256.New, []byte(secret))
	h.Write([]byte("csrf:" + token))
	return hex.EncodeToString(h.Sum(nil))
}

type Auth struct{ DB *gorm.DB }

func (a Auth) CreateUser(ctx context.Context, email, password string) (*dao.User, error) {
	email = strings.ToLower(strings.TrimSpace(email))
	parsed, err := mail.ParseAddress(email)
	if err != nil || parsed.Address != email || len(email) > 254 {
		return nil, errors.New("enter a valid email address")
	}
	if len(password) < 12 || len(password) > 72 {
		return nil, errors.New("password must contain 12–72 bytes")
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return nil, err
	}
	u := dao.User{ID: ID(), Email: email, PasswordHash: string(hash), CreatedAt: time.Now().UTC()}
	if err := a.DB.WithContext(ctx).Create(&u).Error; err != nil {
		return nil, errors.New("account could not be created")
	}
	return &u, nil
}
func (a Auth) Login(ctx context.Context, email, password string) (*dao.User, error) {
	var u dao.User
	err := a.DB.WithContext(ctx).Where("email = ?", strings.ToLower(strings.TrimSpace(email))).First(&u).Error
	if err != nil { // Comparable bcrypt cost for an unknown account.
		_ = bcrypt.CompareHashAndPassword([]byte("$2a$10$7EqJtq98hPqEX7fNZaFWoO5uSlEVqrQRkCQHJMGFQDAkkTvndj.xu"), []byte(password))
		return nil, errors.New("invalid email or password")
	}
	if bcrypt.CompareHashAndPassword([]byte(u.PasswordHash), []byte(password)) != nil {
		return nil, errors.New("invalid email or password")
	}
	return &u, nil
}
func (a Auth) Session(ctx context.Context, user string) (string, error) {
	token := Token()
	now := time.Now().UTC()
	s := dao.Session{Hash: Hash(token), UserID: user, ExpiresAt: now.Add(12 * time.Hour)}
	err := a.DB.WithContext(ctx).Transaction(func(tx *gorm.DB) error {
		var account dao.User
		if err := tx.Clauses(clause.Locking{Strength: "UPDATE"}).First(&account, "id = ?", user).Error; err != nil {
			return err
		}
		if err := tx.Where("expires_at <= ?", now).Delete(&dao.Session{}).Error; err != nil {
			return err
		}
		if err := tx.Create(&s).Error; err != nil {
			return err
		}
		// Keep the newest twenty logins per account; older sessions become invalid immediately.
		return tx.Exec(`DELETE FROM conductor_browser_sessions WHERE user_id = ? AND hash NOT IN (SELECT hash FROM conductor_browser_sessions WHERE user_id = ? ORDER BY expires_at DESC LIMIT 20)`, user, user).Error
	})
	return token, err
}
func (a Auth) User(ctx context.Context, token string) (*dao.User, error) {
	if len(token) != 43 {
		return nil, errors.New("unauthorized")
	}
	var s dao.Session
	if err := a.DB.WithContext(ctx).Where("hash = ? AND expires_at > ?", Hash(token), time.Now().UTC()).First(&s).Error; err != nil {
		return nil, err
	}
	var u dao.User
	return &u, a.DB.WithContext(ctx).First(&u, "id = ?", s.UserID).Error
}
