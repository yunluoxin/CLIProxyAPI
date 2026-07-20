package config

import "testing"

func TestEffectiveUserAgent(t *testing.T) {
	t.Run("nil receiver falls back to default", func(t *testing.T) {
		var cfg *Config
		if got := cfg.EffectiveUserAgent(); got != DefaultUserAgent {
			t.Fatalf("nil cfg: got %q, want %q", got, DefaultUserAgent)
		}
	})

	t.Run("empty falls back to default", func(t *testing.T) {
		cfg := &Config{}
		if got := cfg.EffectiveUserAgent(); got != DefaultUserAgent {
			t.Fatalf("empty cfg: got %q, want %q", got, DefaultUserAgent)
		}
	})

	t.Run("whitespace-only falls back to default", func(t *testing.T) {
		cfg := &Config{UserAgent: "   \t  "}
		if got := cfg.EffectiveUserAgent(); got != DefaultUserAgent {
			t.Fatalf("whitespace cfg: got %q, want %q", got, DefaultUserAgent)
		}
	})

	t.Run("configured value is returned trimmed", func(t *testing.T) {
		cfg := &Config{UserAgent: "  my-custom-ua/1.2.3  "}
		if got := cfg.EffectiveUserAgent(); got != "my-custom-ua/1.2.3" {
			t.Fatalf("custom cfg: got %q, want %q", got, "my-custom-ua/1.2.3")
		}
	})
}
