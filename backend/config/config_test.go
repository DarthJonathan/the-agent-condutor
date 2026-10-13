package config

import "testing"

func TestPublicConfigurationFailsClosed(t *testing.T) {
	c := Config{DatabaseURL: "test", PublicOrigin: "https://conductor.example", SessionSecret: "01234567890123456789012345678901"}
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
	for _, origin := range []string{"HTTPS://conductor.example", "https://conductor.example?"} {
		bad := c
		bad.PublicOrigin = origin
		if bad.Validate() == nil {
			t.Fatal("noncanonical origin accepted", origin)
		}
	}
	for _, change := range []func(*Config){func(c *Config) { c.SessionSecret = "change-me-in-production" }, func(c *Config) { c.PublicOrigin = "http://example.com"; c.Development = true }, func(c *Config) { c.PublicOrigin = "https://user:password@example.com" }, func(c *Config) { c.DatabaseURL = "" }, func(c *Config) { c.PublicOrigin = "https://example.com/path" }} {
		bad := c
		change(&bad)
		if bad.Validate() == nil {
			t.Fatal("unsafe configuration accepted")
		}
	}
	c.Development = true
	c.PublicOrigin = "http://localhost:3005"
	c.AllowSignup = true
	if err := c.Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestProductionSignupIsAnIndependentOptIn(t *testing.T) {
	t.Setenv("DATABASE_URL", "postgres://fixture")
	t.Setenv("PUBLIC_ORIGIN", "https://conductor.example.test")
	t.Setenv("SESSION_SECRET", "01234567890123456789012345678901")
	t.Setenv("DEVELOPMENT", "false")
	for _, value := range []string{"", "false", "true"} {
		t.Setenv("ALLOW_SIGNUP", value)
		c, err := Load()
		if err != nil || c.Development || c.AllowSignup != (value == "true") {
			t.Fatalf("production signup flag %q: config=%+v, error=%v", value, c, err)
		}
		if c.AllowSignup {
			bad := c
			bad.PublicOrigin = "http://conductor.example.test"
			if bad.Validate() == nil {
				t.Fatal("signup bypassed production HTTPS requirement")
			}
			bad = c
			bad.SessionSecret = "short"
			if bad.Validate() == nil {
				t.Fatal("signup bypassed session secret requirement")
			}
		}
	}
}
