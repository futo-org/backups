package handlers

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"support-logs-streamer/internal/auth"
	"support-logs-streamer/internal/otel"
	"support-logs-streamer/internal/stats"

	"github.com/golang-jwt/jwt/v5"
	"go.opentelemetry.io/otel/attribute"
	otellog "go.opentelemetry.io/otel/log"
	sdklog "go.opentelemetry.io/otel/sdk/log"
)

var testPrivateKey, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)

const (
	testUser    = "00000000-0000-0000-0000-000000000001"
	testSession = "00000000-0000-0000-0000-000000000002"
)

type fakeExporter struct {
	mu      sync.Mutex
	fail    bool
	calls   int
	records []sdklog.Record
}

func (e *fakeExporter) Export(_ context.Context, records []sdklog.Record) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.calls++
	if e.fail {
		return errors.New("victoria-logs is down")
	}
	for _, r := range records {
		e.records = append(e.records, r.Clone())
	}
	return nil
}

func (e *fakeExporter) Shutdown(context.Context) error   { return nil }
func (e *fakeExporter) ForceFlush(context.Context) error { return nil }

func token(t *testing.T) string {
	t.Helper()
	signed, err := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"aud":     auth.Audience,
		"sub":     testUser,
		"sid":     testSession,
		"job":     "job-1",
		"jobName": "RepositoryBackup",
		"exp":     jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}).SignedString(testPrivateKey)
	if err != nil {
		t.Fatal(err)
	}
	return signed
}

func gzipped(t *testing.T, body string) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	if _, err := gz.Write([]byte(body)); err != nil {
		t.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func ndjson(lines ...clientLine) string {
	var b strings.Builder
	for _, l := range lines {
		raw, _ := json.Marshal(l)
		b.Write(raw)
		b.WriteByte('\n')
	}
	return b.String()
}

type harness struct {
	exporter *fakeExporter
	tracker  *stats.Tracker
	handler  http.Handler
	server   *Server
}

func newHarness() *harness {
	exporter := &fakeExporter{}
	tracker := stats.NewTracker("http://127.0.0.1:1", "secret")
	srv := &Server{
		JWTPublicKey: &testPrivateKey.PublicKey,
		Sink:         otel.NewSink(exporter, otel.Resource()),
		Stats:        tracker,
	}
	return &harness{exporter: exporter, tracker: tracker, handler: srv.Handler(), server: srv}
}

func (h *harness) post(t *testing.T, body []byte, mutate func(*http.Request)) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/v1/batches", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token(t))
	req.Header.Set("Content-Type", "application/x-ndjson")
	req.Header.Set("Content-Encoding", "gzip")
	req.Header.Set("X-Batch-Seq", "3")
	if mutate != nil {
		mutate(req)
	}
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, req)
	return rec
}

func attrs(r sdklog.Record) map[string]string {
	out := map[string]string{}
	r.WalkAttributes(func(kv attribute.KeyValue) bool {
		out[string(kv.Key)] = kv.Value.String()
		return true
	})
	return out
}

func TestBatchExportsRecords(t *testing.T) {
	h := newHarness()
	at := time.Date(2026, 10, 27, 12, 0, 0, 123, time.UTC)
	body := ndjson(
		clientLine{Time: at.Format(time.RFC3339Nano), Stream: "stdout", Command: "backup", Message: `{"message_type":"verbose_status"}`},
		clientLine{Time: "not a time", Stream: "stderr", Command: "backup", Message: "Load(<data/abc>) returned error, retrying"},
	)

	rec := h.post(t, gzipped(t, body), func(r *http.Request) { r.Header.Set("X-Dropped-Lines", "7") })
	if rec.Code != http.StatusNoContent {
		t.Fatalf("got %d: %s", rec.Code, rec.Body)
	}

	if len(h.exporter.records) != 2 {
		t.Fatalf("expected 2 records, got %d", len(h.exporter.records))
	}

	first := h.exporter.records[0]
	if !first.Timestamp().Equal(at) {
		t.Errorf("timestamp %v, want %v", first.Timestamp(), at)
	}
	if first.Severity() != otellog.SeverityInfo {
		t.Errorf("stdout severity %v", first.Severity())
	}
	if first.Body().AsString() != `{"message_type":"verbose_status"}` {
		t.Errorf("body %q", first.Body().AsString())
	}
	want := map[string]string{
		"user":            testUser,
		"customerId":      testUser,
		"support_session": testSession,
		"job":             "job-1",
		"job_name":        "RepositoryBackup",
		"command":         "backup",
		"stream":          "stdout",
		"batch_seq":       "3",
	}
	got := attrs(first)
	for k, v := range want {
		if got[k] != v {
			t.Errorf("attribute %s = %q, want %q", k, got[k], v)
		}
	}
	if _, ok := got["connection"]; ok {
		t.Error("connection attribute set without a connection claim")
	}

	var service string
	for _, kv := range first.Resource().Attributes() {
		if kv.Key == "service.name" {
			service = kv.Value.AsString()
		}
	}
	if service != "support-logs-streamer" {
		t.Errorf("resource service.name = %q", service)
	}

	second := h.exporter.records[1]
	if second.Severity() != otellog.SeverityWarn {
		t.Errorf("stderr severity %v", second.Severity())
	}
	if time.Since(second.Timestamp()) > time.Minute {
		t.Errorf("unparseable time should fall back to now, got %v", second.Timestamp())
	}
}

func TestBatchCountsMalformedLinesAsDropped(t *testing.T) {
	var reported stats.Delta
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&reported)
		w.WriteHeader(http.StatusNoContent)
	}))
	defer api.Close()

	h := newHarness()
	h.server.Stats = stats.NewTracker(api.URL, "secret")
	body := ndjson(clientLine{Stream: "stdout", Message: "ok"}) +
		"not json\n" +
		ndjson(clientLine{Stream: "bogus", Message: "unknown stream"}) +
		"\n"

	rec := h.post(t, gzipped(t, body), func(r *http.Request) { r.Header.Set("X-Dropped-Lines", "4") })
	if rec.Code != http.StatusNoContent {
		t.Fatalf("got %d: %s", rec.Code, rec.Body)
	}
	h.server.Stats.Flush(context.Background())

	if reported.Lines != 1 || reported.DroppedLines != 6 || reported.Batches != 1 || reported.Bytes != int64(len(body)) {
		t.Errorf("unexpected stats %+v", reported)
	}
}

func TestBatchTruncatesLongMessages(t *testing.T) {
	h := newHarness()
	long := strings.Repeat("é", maxMessageBytes)
	rec := h.post(t, gzipped(t, ndjson(clientLine{Stream: "stdout", Message: long})), nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("got %d", rec.Code)
	}
	body := h.exporter.records[0].Body().AsString()
	if len(body) > maxMessageBytes || !strings.HasPrefix(long, body) {
		t.Errorf("message not truncated on a rune boundary: %d bytes", len(body))
	}
}

func TestBatchExportsInChunks(t *testing.T) {
	h := newHarness()
	line := ndjson(clientLine{Stream: "stdout", Message: strings.Repeat("x", 60<<10)})
	lines := (exportChunkBytes/len(line))*2 + 1
	body := strings.Repeat(line, lines)

	rec := h.post(t, gzipped(t, body), nil)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("got %d", rec.Code)
	}
	if h.exporter.calls < 2 {
		t.Errorf("expected the batch to be split across exports, got %d calls", h.exporter.calls)
	}
	if len(h.exporter.records) != lines {
		t.Errorf("exported %d records, want %d", len(h.exporter.records), lines)
	}
}

func TestBatchExportFailureAsksForRetry(t *testing.T) {
	h := newHarness()
	h.exporter.fail = true
	rec := h.post(t, gzipped(t, ndjson(clientLine{Stream: "stdout", Message: "x"})), nil)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("got %d, want 503", rec.Code)
	}
}

func TestBatchRejectsBadRequests(t *testing.T) {
	valid := gzipped(t, ndjson(clientLine{Stream: "stdout", Message: "x"}))

	cases := map[string]struct {
		body   []byte
		mutate func(*http.Request)
		want   int
	}{
		"no token":         {valid, func(r *http.Request) { r.Header.Del("Authorization") }, http.StatusUnauthorized},
		"not gzip":         {valid, func(r *http.Request) { r.Header.Del("Content-Encoding") }, http.StatusBadRequest},
		"wrong type":       {valid, func(r *http.Request) { r.Header.Set("Content-Type", "application/json") }, http.StatusBadRequest},
		"missing seq":      {valid, func(r *http.Request) { r.Header.Del("X-Batch-Seq") }, http.StatusBadRequest},
		"negative seq":     {valid, func(r *http.Request) { r.Header.Set("X-Batch-Seq", "-1") }, http.StatusBadRequest},
		"bad dropped":      {valid, func(r *http.Request) { r.Header.Set("X-Dropped-Lines", "many") }, http.StatusBadRequest},
		"corrupt gzip":     {[]byte("definitely not gzip"), nil, http.StatusBadRequest},
		"truncated gzip":   {valid[:len(valid)-6], nil, http.StatusBadRequest},
		"compressed bomb":  {gzipped(t, strings.Repeat("a", maxDecompressedBytes+10)), nil, http.StatusRequestEntityTooLarge},
		"type with params": {valid, func(r *http.Request) { r.Header.Set("Content-Type", "application/x-ndjson; charset=utf-8") }, http.StatusNoContent},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			rec := newHarness().post(t, tc.body, tc.mutate)
			if rec.Code != tc.want {
				t.Errorf("got %d, want %d: %s", rec.Code, tc.want, rec.Body)
			}
		})
	}
}

func TestBatchRejectsOversizedBody(t *testing.T) {
	random := make([]byte, maxCompressedBytes+1)
	_, _ = rand.Read(random)
	rec := newHarness().post(t, random, nil)
	if rec.Code != http.StatusRequestEntityTooLarge && rec.Code != http.StatusBadRequest {
		t.Fatalf("got %d", rec.Code)
	}

	var buf bytes.Buffer
	gz, _ := gzip.NewWriterLevel(&buf, gzip.NoCompression)
	_, _ = fmt.Fprint(gz, strings.Repeat(ndjson(clientLine{Stream: "stdout", Message: "x"}), (maxCompressedBytes/40)+1))
	_ = gz.Close()
	rec = newHarness().post(t, buf.Bytes(), nil)
	if rec.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("got %d, want 413", rec.Code)
	}
}

func TestReadiness(t *testing.T) {
	h := newHarness()
	rec := httptest.NewRecorder()
	h.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("got %d before draining", rec.Code)
	}

	h.server.BeginDrain()
	rec = httptest.NewRecorder()
	h.handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("got %d while draining", rec.Code)
	}
}
