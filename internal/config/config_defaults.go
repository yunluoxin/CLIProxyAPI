package config

import "strings"

const (
	DefaultPanelGitHubRepository = "https://github.com/router-for-me/Cli-Proxy-API-Management-Center"
	DefaultPprofAddr             = "127.0.0.1:8316"
	DefaultAuthDir               = "~/.cli-proxy-api"
	DefaultDiscoveryServiceType  = "_ai-gateway._tcp"
	// DefaultUserAgent is the User-Agent header value used when the user has not
	// configured their own in config.yaml (`user-agent`).
	DefaultUserAgent = "cli-proxy-openai-compat"
)

// EffectiveUserAgent returns the configured User-Agent override, falling back
// to DefaultUserAgent when unset or whitespace-only. Safe to call on a nil
// receiver — it always returns DefaultUserAgent.
func (cfg *Config) EffectiveUserAgent() string {
	if cfg == nil {
		return DefaultUserAgent
	}
	if ua := strings.TrimSpace(cfg.UserAgent); ua != "" {
		return ua
	}
	return DefaultUserAgent
}
