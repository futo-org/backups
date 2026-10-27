package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"support-logs-streamer/internal/config"
	"support-logs-streamer/internal/handlers"
	"support-logs-streamer/internal/otel"
	"support-logs-streamer/internal/stats"
	"support-logs-streamer/internal/version"

	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
)

func main() {
	zerolog.TimeFieldFormat = time.RFC3339
	zerolog.TimestampFunc = func() time.Time { return time.Now().UTC() }

	cfg := config.LoadConfig()

	var output io.Writer = os.Stderr
	if cfg.LogPretty {
		output = zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.RFC3339}
	}
	log.Logger = zerolog.New(output).With().Timestamp().Caller().Logger()
	zerolog.SetGlobalLevel(cfg.LogLevel)

	addr := fmt.Sprintf(":%d", cfg.Port)
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal().Err(err).Str("addr", addr).Msg("failed to bind listener")
	}

	exporter, err := otel.NewOTLPExporter(context.Background(), cfg)
	if err != nil {
		log.Fatal().Err(err).Msg("failed to setup OTLP log exporter")
	}
	sink := otel.NewSink(exporter, otel.Resource())
	log.Info().Str("endpoint", cfg.OTLPLogsEndpoint).Msg("exporting client logs over OTLP")

	var meterProvider *sdkmetric.MeterProvider
	var m *handlers.Metrics
	if cfg.OTLPMetricsEnabled {
		meterProvider, err = otel.SetupMeterProvider(context.Background(), cfg)
		if err != nil {
			log.Fatal().Err(err).Msg("failed to setup meter provider")
		}
		m, err = handlers.NewMetrics(meterProvider.Meter("support-logs-streamer"))
		if err != nil {
			log.Fatal().Err(err).Msg("failed to create metrics")
		}
		log.Info().Str("endpoint", cfg.OTLPMetricsEndpoint).Msg("OpenTelemetry metrics enabled")
	}

	tracker := stats.NewTracker(cfg.YuccaAPIURL, cfg.InternalSecret)
	srv := &handlers.Server{
		JWTPublicKey: cfg.JWTPublicKey,
		Sink:         sink,
		Stats:        tracker,
		Metrics:      m,
	}

	// No WriteTimeout: a batch is acknowledged only after its synchronous
	// export, which the OTLP exporter may spend a minute retrying.
	httpSrv := &http.Server{
		Addr:              addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       2 * time.Minute,
		IdleTimeout:       2 * time.Minute,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	statsCtx, stopStats := context.WithCancel(context.Background())
	defer stopStats()
	statsDone := make(chan struct{})
	go func() {
		defer close(statsDone)
		tracker.Run(statsCtx, cfg.StatsFlushInterval)
	}()

	go func() {
		log.Info().Int("port", cfg.Port).Str("version", version.Version).Msg("starting support-logs-streamer")
		if err := httpSrv.Serve(listener); err != nil && err != http.ErrServerClosed {
			log.Fatal().Err(err).Msg("server error")
		}
	}()

	<-ctx.Done()
	stop()

	if err := drain(srv, httpSrv, cfg.DrainDelay, cfg.ShutdownTimeout); err != nil {
		log.Error().Err(err).Msg("shutdown deadline hit with requests still in flight")
	}
	stopStats()
	<-statsDone
	tracker.Wait()

	telemetryCtx, cancelTelemetry := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancelTelemetry()

	tracker.Flush(telemetryCtx)

	if err := sink.Shutdown(telemetryCtx); err != nil {
		log.Error().Err(err).Msg("OTLP log exporter shutdown error")
	}
	if meterProvider != nil {
		if err := meterProvider.Shutdown(telemetryCtx); err != nil {
			log.Error().Err(err).Msg("meter provider shutdown error")
		}
	}

	log.Info().Msg("shutdown complete")
}

func drain(srv *handlers.Server, httpSrv *http.Server, delay, timeout time.Duration) error {
	srv.BeginDrain()
	log.Info().Dur("drain_delay", delay).Msg("draining: readiness failing, still serving")
	time.Sleep(delay)

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	log.Info().Dur("timeout", timeout).Msg("closing listener, waiting for in-flight requests")
	return httpSrv.Shutdown(ctx)
}
