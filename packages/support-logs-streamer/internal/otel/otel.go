package otel

import (
	"context"
	"os"

	"support-logs-streamer/internal/config"
	"support-logs-streamer/internal/version"

	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	sdkresource "go.opentelemetry.io/otel/sdk/resource"
)

const serviceName = "support-logs-streamer"

// Resource identifies this process to the collector. Without
// service.instance.id every replica exports identical metric series, which the
// TSDB merges into one and reads as counter resets.
func Resource() *sdkresource.Resource {
	host, _ := os.Hostname()
	res, err := sdkresource.Merge(sdkresource.Default(), sdkresource.NewSchemaless(
		attribute.String("service.name", serviceName),
		attribute.String("service.version", version.Version),
		attribute.String("service.instance.id", host),
	))
	if err != nil {
		return sdkresource.Default()
	}
	return res
}

// Sink exports client log lines synchronously. The provider only stamps the
// resource and scope onto records; its processor hands them back to the
// emitting request instead of queueing them, so the request can export them
// itself and tell the client whether VictoriaLogs has them. A batching
// processor would acknowledge lines it might still drop.
type Sink struct {
	provider *sdklog.LoggerProvider
	logger   otellog.Logger
	exporter sdklog.Exporter
}

func NewSink(exporter sdklog.Exporter, res *sdkresource.Resource) *Sink {
	provider := sdklog.NewLoggerProvider(
		sdklog.WithResource(res),
		sdklog.WithProcessor(collectingProcessor{}),
	)
	return &Sink{
		provider: provider,
		logger:   provider.Logger(serviceName),
		exporter: exporter,
	}
}

func NewOTLPExporter(ctx context.Context, cfg config.Config, extra ...otlploghttp.Option) (sdklog.Exporter, error) {
	opts := []otlploghttp.Option{otlploghttp.WithEndpoint(cfg.OTLPLogsEndpoint)}
	if cfg.OTLPLogsInsecure {
		opts = append(opts, otlploghttp.WithInsecure())
	}
	if cfg.OTLPLogsURLPath != "" {
		opts = append(opts, otlploghttp.WithURLPath(cfg.OTLPLogsURLPath))
	}
	return otlploghttp.New(ctx, append(opts, extra...)...)
}

type Batch struct {
	sink    *Sink
	records []sdklog.Record
}

func (s *Sink) NewBatch() *Batch {
	return &Batch{sink: s}
}

func (b *Batch) Emit(ctx context.Context, record otellog.Record) {
	b.sink.logger.Emit(context.WithValue(ctx, batchKey{}, b), record)
}

func (b *Batch) Len() int {
	return len(b.records)
}

func (b *Batch) Export(ctx context.Context) error {
	if len(b.records) == 0 {
		return nil
	}
	err := b.sink.exporter.Export(ctx, b.records)
	b.records = b.records[:0]
	return err
}

func (s *Sink) Shutdown(ctx context.Context) error {
	if err := s.provider.Shutdown(ctx); err != nil {
		return err
	}
	return s.exporter.Shutdown(ctx)
}

type batchKey struct{}

type collectingProcessor struct{}

func (collectingProcessor) Enabled(context.Context, sdklog.EnabledParameters) bool { return true }

// OnEmit must clone: the SDK reuses the record it passes in once OnEmit returns.
func (collectingProcessor) OnEmit(ctx context.Context, record *sdklog.Record) error {
	if b, ok := ctx.Value(batchKey{}).(*Batch); ok {
		b.records = append(b.records, record.Clone())
	}
	return nil
}

func (collectingProcessor) Shutdown(context.Context) error   { return nil }
func (collectingProcessor) ForceFlush(context.Context) error { return nil }

func SetupMeterProvider(ctx context.Context, cfg config.Config) (*sdkmetric.MeterProvider, error) {
	opts := []otlpmetrichttp.Option{
		otlpmetrichttp.WithEndpoint(cfg.OTLPMetricsEndpoint),
		otlpmetrichttp.WithInsecure(),
	}
	if cfg.OTLPMetricsURLPath != "" {
		opts = append(opts, otlpmetrichttp.WithURLPath(cfg.OTLPMetricsURLPath))
	}

	exporter, err := otlpmetrichttp.New(ctx, opts...)
	if err != nil {
		return nil, err
	}

	return sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(Resource()),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter, sdkmetric.WithInterval(cfg.OTLPMetricsInterval))),
	), nil
}
