package handlers

import (
	"crypto/ecdsa"
	"fmt"
	"net/http"
	"sync/atomic"
	"time"

	"support-logs-streamer/internal/auth"
	"support-logs-streamer/internal/otel"
	"support-logs-streamer/internal/stats"

	"github.com/go-chi/chi/v5"
	chimw "github.com/go-chi/chi/v5/middleware"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/hlog"
	"github.com/rs/zerolog/log"
	otelmetric "go.opentelemetry.io/otel/metric"
)

type Server struct {
	JWTPublicKey *ecdsa.PublicKey
	Sink         *otel.Sink
	Stats        *stats.Tracker
	Metrics      *Metrics

	draining atomic.Bool
}

const readyPath = "/readyz"

// BeginDrain fails readiness while still serving, so the gateway moves new
// batches to another replica before the listener closes.
func (s *Server) BeginDrain() { s.draining.Store(true) }

func (s *Server) Handler() http.Handler {
	r := chi.NewRouter()
	r.Use(hlog.NewHandler(log.Logger))
	r.Use(hlog.RequestIDHandler("request_id", "X-Request-Id"))
	r.Use(hlog.RemoteAddrHandler("remote_ip"))
	r.Use(hlog.UserAgentHandler("user_agent"))
	r.Use(hlog.AccessHandler(func(r *http.Request, status, size int, duration time.Duration) {
		route := chi.RouteContext(r.Context()).RoutePattern()
		if route == "" {
			route = r.URL.Path
		}
		hlog.FromRequest(r).Info().
			Int("status", status).
			Int("size", size).
			Dur("duration", duration).
			Str("method", r.Method).
			Str("path", r.URL.Path).
			Msgf("%s %s (%d)", r.Method, route, status)
	}))
	r.Use(chimw.Recoverer)

	r.Group(func(r chi.Router) {
		r.Use(auth.Middleware(s.JWTPublicKey))
		r.Use(authLogContext)
		r.Post("/v1/batches", s.postBatch)
	})

	return s.withReadiness(r)
}

func (s *Server) withReadiness(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != readyPath {
			next.ServeHTTP(w, r)
			return
		}
		if s.draining.Load() {
			http.Error(w, "draining", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
}

func authLogContext(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		session := auth.FromContext(r.Context())
		hlog.FromRequest(r).UpdateContext(func(c zerolog.Context) zerolog.Context {
			return c.Str("user", session.User).Str("support_session", session.Session).Str("job", session.Job)
		})
		next.ServeHTTP(w, r)
	})
}

type Metrics struct {
	Batches        otelmetric.Int64Counter
	Lines          otelmetric.Int64Counter
	Bytes          otelmetric.Int64Counter
	MalformedLines otelmetric.Int64Counter
	ExportFailures otelmetric.Int64Counter
}

func NewMetrics(meter otelmetric.Meter) (*Metrics, error) {
	batches, err := meter.Int64Counter("support_logs.batches",
		otelmetric.WithDescription("Client log batches accepted"))
	if err != nil {
		return nil, fmt.Errorf("creating batches counter: %w", err)
	}
	lines, err := meter.Int64Counter("support_logs.lines",
		otelmetric.WithDescription("Client log lines exported"))
	if err != nil {
		return nil, fmt.Errorf("creating lines counter: %w", err)
	}
	bytes, err := meter.Int64Counter("support_logs.bytes",
		otelmetric.WithDescription("Decompressed client log bytes received"),
		otelmetric.WithUnit("By"))
	if err != nil {
		return nil, fmt.Errorf("creating bytes counter: %w", err)
	}
	malformed, err := meter.Int64Counter("support_logs.malformed_lines",
		otelmetric.WithDescription("Client log lines skipped as malformed"))
	if err != nil {
		return nil, fmt.Errorf("creating malformed_lines counter: %w", err)
	}
	exportFailures, err := meter.Int64Counter("support_logs.export_failures",
		otelmetric.WithDescription("Batches rejected because the OTLP export failed"))
	if err != nil {
		return nil, fmt.Errorf("creating export_failures counter: %w", err)
	}
	return &Metrics{
		Batches:        batches,
		Lines:          lines,
		Bytes:          bytes,
		MalformedLines: malformed,
		ExportFailures: exportFailures,
	}, nil
}
