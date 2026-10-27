package otel

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"support-logs-streamer/internal/config"

	"go.opentelemetry.io/otel/attribute"
	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	collogspb "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	"google.golang.org/protobuf/proto"
)

func TestBatchExportReachesTheCollector(t *testing.T) {
	requests := make(chan *collogspb.ExportLogsServiceRequest, 4)
	collector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/insert/opentelemetry/v1/logs" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		var req collogspb.ExportLogsServiceRequest
		if err := proto.Unmarshal(body, &req); err != nil {
			t.Errorf("collector got an undecodable body: %v", err)
		}
		requests <- &req
		w.WriteHeader(http.StatusOK)
	}))
	defer collector.Close()

	u, _ := url.Parse(collector.URL)
	exporter, err := NewOTLPExporter(context.Background(), config.Config{
		OTLPLogsEndpoint: u.Host,
		OTLPLogsURLPath:  "/insert/opentelemetry/v1/logs",
	})
	if err != nil {
		t.Fatal(err)
	}
	sink := NewSink(exporter, Resource())
	defer func() { _ = sink.Shutdown(context.Background()) }()

	batch := sink.NewBatch()
	for _, message := range []string{"first", "second"} {
		var record otellog.Record
		record.SetBody(attribute.StringValue(message))
		record.AddAttributes(attribute.String("support_session", "s1"))
		batch.Emit(context.Background(), record)
	}
	if batch.Len() != 2 {
		t.Fatalf("batch collected %d records", batch.Len())
	}
	if err := batch.Export(context.Background()); err != nil {
		t.Fatalf("export failed: %v", err)
	}
	if batch.Len() != 0 {
		t.Error("batch not emptied after export")
	}

	req := <-requests
	resourceLogs := req.GetResourceLogs()
	if len(resourceLogs) != 1 {
		t.Fatalf("expected one resource, got %d", len(resourceLogs))
	}
	var service string
	for _, kv := range resourceLogs[0].GetResource().GetAttributes() {
		if kv.GetKey() == "service.name" {
			service = kv.GetValue().GetStringValue()
		}
	}
	if service != "support-logs-streamer" {
		t.Errorf("service.name = %q", service)
	}

	var bodies []string
	for _, scope := range resourceLogs[0].GetScopeLogs() {
		for _, record := range scope.GetLogRecords() {
			bodies = append(bodies, record.GetBody().GetStringValue())
		}
	}
	if len(bodies) != 2 || bodies[0] != "first" || bodies[1] != "second" {
		t.Errorf("collector received %v", bodies)
	}
}

func TestEmitOutsideABatchIsDropped(t *testing.T) {
	exporter := &countingExporter{}
	sink := NewSink(exporter, Resource())
	var record otellog.Record
	sink.logger.Emit(context.Background(), record)
	if err := sink.NewBatch().Export(context.Background()); err != nil {
		t.Fatal(err)
	}
	if exporter.calls != 0 {
		t.Errorf("an empty batch should not export, got %d calls", exporter.calls)
	}
}

type countingExporter struct{ calls int }

func (e *countingExporter) Export(context.Context, []sdklog.Record) error {
	e.calls++
	return nil
}
func (e *countingExporter) Shutdown(context.Context) error   { return nil }
func (e *countingExporter) ForceFlush(context.Context) error { return nil }
