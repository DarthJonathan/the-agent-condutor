package config

import (
	"errors"
	"net/url"
	"os"
	"strings"
)

type Config struct {
	Addr, DatabaseURL, PublicOrigin, SessionSecret string
	Development, AllowSignup                       bool
}

func Load() (Config, error) {
	c := Config{Addr: env("LISTEN_ADDR", ":8080"), DatabaseURL: os.Getenv("DATABASE_URL"), PublicOrigin: strings.TrimRight(os.Getenv("PUBLIC_ORIGIN"), "/"), SessionSecret: os.Getenv("SESSION_SECRET"), Development: os.Getenv("DEVELOPMENT") == "true", AllowSignup: os.Getenv("ALLOW_SIGNUP") == "true"}
	return c, c.Validate()
}
func (c Config) Validate() error {
	u, err := url.Parse(c.PublicOrigin)
	if err != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.Path != "" || !strings.HasPrefix(c.PublicOrigin, u.Scheme+"://") {
		return errors.New("PUBLIC_ORIGIN must be an origin without a path")
	}
	loopback := u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1" || u.Hostname() == "::1"
	if u.Scheme != "https" && !(c.Development && loopback && u.Scheme == "http") {
		return errors.New("HTTPS is required; development HTTP is limited to loopback")
	}
	if len(c.SessionSecret) < 32 || strings.Contains(c.SessionSecret, "change-me") {
		return errors.New("SESSION_SECRET must contain at least 32 non-default characters")
	}
	if c.DatabaseURL == "" {
		return errors.New("DATABASE_URL is required")
	}
	return nil
}
func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
func (c Config) CookieName() string {
	if strings.HasPrefix(c.PublicOrigin, "https://") {
		return "__Host-conductor-session"
	}
	return "conductor-session"
}
