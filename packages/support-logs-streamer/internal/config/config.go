package config

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/x509"
	"encoding/pem"
	"net/url"
	"os"
	"strconv"
	"time"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

type Config struct {
	Port         int
	JWTPublicKey *ecdsa.PublicKey

	YuccaAPIURL        string
	InternalSecret     string
	StatsFlushInterval time.Duration

	DrainDelay      time.Duration
	ShutdownTimeout time.Duration

	OTLPLogsEndpoint string
	OTLPLogsURLPath  string

	OTLPMetricsEndpoint string
	OTLPMetricsURLPath  string
	OTLPMetricsInterval time.Duration
	OTLPMetricsEnabled  bool

	LogLevel  zerolog.Level
	LogPretty bool
}

func LoadConfig() Config {
	port := envIntMin("SUPPORT_LOGS_PORT", 0, 1000)
	if port == 0 {
		log.Fatal().Msg("SUPPORT_LOGS_PORT is required")
	}

	yuccaAPIURL := os.Getenv("YUCCA_API_URL")
	if yuccaAPIURL == "" {
		log.Fatal().Msg("YUCCA_API_URL is required")
	}
	if u, err := url.Parse(yuccaAPIURL); err != nil || u.Scheme == "" || u.Host == "" {
		log.Fatal().Str("value", yuccaAPIURL).Msg("YUCCA_API_URL must be an absolute URL, including yucca-api's /api prefix")
	}

	internalSecret := os.Getenv("INTERNAL_SECRET")
	if internalSecret == "" {
		log.Fatal().Msg("INTERNAL_SECRET is required")
	}

	// Unlike michael, this service has no reason to run without its sink: every
	// accepted batch is acknowledged only once VictoriaLogs has it.
	otlpLogsEndpoint := os.Getenv("OTLP_LOGS_ENDPOINT")
	if otlpLogsEndpoint == "" {
		log.Fatal().Msg("OTLP_LOGS_ENDPOINT is required")
	}

	logLevel := zerolog.InfoLevel
	if v := os.Getenv("LOG_LEVEL"); v != "" {
		parsed, err := zerolog.ParseLevel(v)
		if err != nil {
			log.Fatal().Str("value", v).Msg("LOG_LEVEL must be a valid level (trace, debug, info, warn, error, fatal, panic)")
		}
		logLevel = parsed
	}

	logPretty := false
	if v := os.Getenv("LOG_FORMAT"); v != "" {
		switch v {
		case "json":
		case "pretty":
			logPretty = true
		default:
			log.Fatal().Str("value", v).Msg("LOG_FORMAT must be 'json' or 'pretty'")
		}
	}

	otlpMetricsEndpoint := os.Getenv("OTLP_METRICS_ENDPOINT")

	return Config{
		Port:                port,
		JWTPublicKey:        parseES256PublicKey(os.Getenv("JWT_PUBLIC_KEY")),
		YuccaAPIURL:         yuccaAPIURL,
		InternalSecret:      internalSecret,
		StatsFlushInterval:  envDurationMS("STATS_FLUSH_INTERVAL_MS", 15*time.Second),
		DrainDelay:          envDurationMS("DRAIN_DELAY_MS", 15*time.Second),
		ShutdownTimeout:     envDurationMS("SHUTDOWN_TIMEOUT_MS", 60*time.Second),
		OTLPLogsEndpoint:    otlpLogsEndpoint,
		OTLPLogsURLPath:     os.Getenv("OTLP_LOGS_URL_PATH"),
		OTLPMetricsEndpoint: otlpMetricsEndpoint,
		OTLPMetricsURLPath:  os.Getenv("OTLP_METRICS_URL_PATH"),
		OTLPMetricsInterval: envDurationMS("OTLP_METRICS_INTERVAL_MS", 60*time.Second),
		OTLPMetricsEnabled:  otlpMetricsEndpoint != "",
		LogLevel:            logLevel,
		LogPretty:           logPretty,
	}
}

func envIntMin(key string, fallback, minimum int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < minimum {
		log.Fatal().Msgf("%s must be a number >= %d", key, minimum)
	}
	return n
}

func envDurationMS(key string, fallback time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	ms, err := strconv.Atoi(v)
	if err != nil || ms < 0 {
		log.Fatal().Msgf("%s must be a number >= 0", key)
	}
	return time.Duration(ms) * time.Millisecond
}

func parseES256PublicKey(key string) *ecdsa.PublicKey {
	if key == "" {
		log.Fatal().Msg("JWT_PUBLIC_KEY is required")
	}

	block, _ := pem.Decode([]byte(key))
	if block == nil {
		log.Fatal().Msg("JWT_PUBLIC_KEY must be a PEM-encoded ECDSA P-256 public key")
	}

	parsed, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		log.Fatal().Err(err).Msg("JWT_PUBLIC_KEY could not be parsed")
	}

	pub, ok := parsed.(*ecdsa.PublicKey)
	if !ok {
		log.Fatal().Msg("JWT_PUBLIC_KEY must be an ECDSA public key")
	}
	if pub.Curve != elliptic.P256() {
		log.Fatal().Msg("JWT_PUBLIC_KEY must use the P-256 curve (ES256)")
	}

	return pub
}
