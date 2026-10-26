package handlers

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"michael/internal/metrics"
	"michael/internal/storage"

	"github.com/golang-jwt/jwt/v5"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/metric/metricdata"
)

func newMeteredServer(t *testing.T, store *mockStorage) (*Server, *metric.ManualReader) {
	t.Helper()
	reader := metric.NewManualReader()
	m, err := metrics.NewMetrics(metric.NewMeterProvider(metric.WithReader(reader)).Meter("test"))
	if err != nil {
		t.Fatalf("NewMetrics: %v", err)
	}
	return NewServer(store, testPublicKey, m), reader
}

func cancelledContext() context.Context {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	return ctx
}

// The SDK surfaces either the body's EOF or context.Canceled for the same
// disconnect; the guard must not depend on which.
func TestSaveBlob_ClientDisconnectIsNotAStorageError(t *testing.T) {
	for name, storeErr := range map[string]error{
		"body EOF":         fmt.Errorf("put object: %w", io.ErrUnexpectedEOF),
		"context canceled": fmt.Errorf("put object: %w", context.Canceled),
	} {
		t.Run(name, func(t *testing.T) {
			buf := captureLogOutput(t)
			store := &mockStorage{
				putObjectFn: func(_ context.Context, _, _ string, body io.Reader, _ int64, _ bool, _ string) error {
					_, _ = io.Copy(io.Discard, body)
					return storeErr
				},
			}
			srv, reader := newMeteredServer(t, store)

			rec := doRequestWithContext(t, cancelledContext(), srv, http.MethodPost, "/"+testRepository+"/data/"+testBlobName, strings.NewReader("half a pack"), defaultAuth(), nil)

			if rec.Code != StatusClientClosedRequest {
				t.Fatalf("expected %d, got %d: %s", StatusClientClosedRequest, rec.Code, rec.Body.String())
			}

			entries := parseLogLines(t, buf)
			if e := findLog(entries, map[string]any{"level": "error"}); e != nil {
				t.Errorf("client disconnect logged at error level: %v", e)
			}
			if findLog(entries, map[string]any{"level": "warn", "message": "save blob aborted: client disconnected"}) == nil {
				t.Errorf("no warn entry for the aborted upload:\n%s", buf.String())
			}
			if findLog(entries, map[string]any{"status": float64(StatusClientClosedRequest)}) == nil {
				t.Errorf("no access log entry with status %d:\n%s", StatusClientClosedRequest, buf.String())
			}

			if got := counterSum(t, reader, "http.server.request.count", withStatus(StatusClientClosedRequest)); got != 1 {
				t.Errorf("http.server.request.count{status=%d} = %d, want 1", StatusClientClosedRequest, got)
			}
			if got := counterSum(t, reader, "storage.backend.errors", anyAttrs); got != 0 {
				t.Errorf("storage.backend.errors = %d, want 0", got)
			}
		})
	}
}

func expiredContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithDeadline(context.Background(), time.Unix(0, 0))
	t.Cleanup(cancel)
	return ctx
}

func TestSaveBlob_BackendFailureStillCountsAsStorageError(t *testing.T) {
	for name, tc := range map[string]struct {
		ctx context.Context
		err error
	}{
		"dial refused":      {context.Background(), errors.New("put object: dial tcp: connection refused")},
		"backend truncated": {context.Background(), fmt.Errorf("put object: %w", io.ErrUnexpectedEOF)},
		"backend cancelled": {context.Background(), fmt.Errorf("put object: %w", context.Canceled)},
		"deadline exceeded": {expiredContext(t), fmt.Errorf("put object: %w", context.DeadlineExceeded)},
	} {
		t.Run(name, func(t *testing.T) {
			buf := captureLogOutput(t)
			store := &mockStorage{
				putObjectFn: func(_ context.Context, _, _ string, body io.Reader, _ int64, _ bool, _ string) error {
					_, _ = io.Copy(io.Discard, body)
					return tc.err
				},
			}
			srv, reader := newMeteredServer(t, store)

			rec := doRequestWithContext(t, tc.ctx, srv, http.MethodPost, "/"+testRepository+"/data/"+testBlobName, strings.NewReader("a pack"), defaultAuth(), nil)

			if rec.Code != http.StatusInternalServerError {
				t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
			}
			entries := parseLogLines(t, buf)
			if findLog(entries, map[string]any{"level": "error", "message": "save blob failed: backend storage error"}) == nil {
				t.Errorf("no error entry for the backend failure:\n%s", buf.String())
			}
			if e := findLog(entries, map[string]any{"message": "save blob aborted: client disconnected"}); e != nil {
				t.Errorf("backend failure booked as a client disconnect: %v", e)
			}
			if got := counterSum(t, reader, "http.server.request.count", withStatus(http.StatusInternalServerError)); got != 1 {
				t.Errorf("http.server.request.count{status=500} = %d, want 1", got)
			}
			if got := counterSum(t, reader, "http.server.request.count", withStatus(StatusClientClosedRequest)); got != 0 {
				t.Errorf("http.server.request.count{status=%d} = %d, want 0", StatusClientClosedRequest, got)
			}
			if got := counterSum(t, reader, "storage.backend.errors", anyAttrs); got != 1 {
				t.Errorf("storage.backend.errors = %d, want 1", got)
			}
		})
	}
}

func TestSaveBlob_StoredBeforeDisconnectIsStill200(t *testing.T) {
	buf := captureLogOutput(t)
	store := &mockStorage{
		putObjectFn: func(_ context.Context, _, _ string, body io.Reader, _ int64, _ bool, _ string) error {
			_, _ = io.Copy(io.Discard, body)
			return nil
		},
	}
	srv, reader := newMeteredServer(t, store)

	rec := doRequestWithContext(t, cancelledContext(), srv, http.MethodPost, "/"+testRepository+"/data/"+testBlobName, strings.NewReader("a pack"), defaultAuth(), nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if e := findLog(parseLogLines(t, buf), map[string]any{"message": "save blob aborted: client disconnected"}); e != nil {
		t.Errorf("stored blob booked as aborted: %v", e)
	}
	if got := counterSum(t, reader, "blobs.stored_bytes", anyAttrs); got != int64(len("a pack")) {
		t.Errorf("blobs.stored_bytes = %d, want %d", got, len("a pack"))
	}
}

func TestCheckBlob_ClientDisconnectIsNotAStorageError(t *testing.T) {
	buf := captureLogOutput(t)
	store := &mockStorage{
		headObjectFn: func(ctx context.Context, _, _ string) (int64, error) {
			return 0, fmt.Errorf("head object: %w", ctx.Err())
		},
	}
	srv := newTestServer(store)

	rec := doRequestWithContext(t, cancelledContext(), srv, http.MethodHead, "/"+testRepository+"/data/"+testBlobName, nil, defaultAuth(), nil)

	if rec.Code != StatusClientClosedRequest {
		t.Fatalf("expected %d, got %d", StatusClientClosedRequest, rec.Code)
	}
	entries := parseLogLines(t, buf)
	if e := findLog(entries, map[string]any{"level": "error"}); e != nil {
		t.Errorf("client disconnect logged at error level: %v", e)
	}
	if findLog(entries, map[string]any{"level": "warn", "message": "head blob aborted: client disconnected"}) == nil {
		t.Errorf("no warn entry for the aborted HEAD:\n%s", buf.String())
	}
}

func TestGetBlob_ClientDisconnectIsNotAStorageError(t *testing.T) {
	buf := captureLogOutput(t)
	store := &mockStorage{
		getObjectFn: func(ctx context.Context, _, _, _ string) (*storage.S3Object, error) {
			return nil, fmt.Errorf("get object: %w", ctx.Err())
		},
	}
	srv, reader := newMeteredServer(t, store)

	rec := doRequestWithContext(t, cancelledContext(), srv, http.MethodGet, "/"+testRepository+"/data/"+testBlobName, nil, defaultAuth(), nil)

	if rec.Code != StatusClientClosedRequest {
		t.Fatalf("expected %d, got %d: %s", StatusClientClosedRequest, rec.Code, rec.Body.String())
	}
	entries := parseLogLines(t, buf)
	if e := findLog(entries, map[string]any{"level": "error"}); e != nil {
		t.Errorf("client disconnect logged at error level: %v", e)
	}
	if findLog(entries, map[string]any{"level": "warn", "message": "get blob aborted: client disconnected"}) == nil {
		t.Errorf("no warn entry for the aborted GET:\n%s", buf.String())
	}
	if got := counterSum(t, reader, "storage.backend.errors", anyAttrs); got != 0 {
		t.Errorf("storage.backend.errors = %d, want 0", got)
	}
}

func counterSum(t *testing.T, reader *metric.ManualReader, name string, match func(attribute.Set) bool) int64 {
	t.Helper()
	var rm metricdata.ResourceMetrics
	if err := reader.Collect(context.Background(), &rm); err != nil {
		t.Fatalf("collect metrics: %v", err)
	}
	var total int64
	for _, sm := range rm.ScopeMetrics {
		for _, md := range sm.Metrics {
			if md.Name != name {
				continue
			}
			sum, ok := md.Data.(metricdata.Sum[int64])
			if !ok {
				t.Fatalf("%s is not an int64 sum: %T", name, md.Data)
			}
			for _, dp := range sum.DataPoints {
				if match(dp.Attributes) {
					total += dp.Value
				}
			}
		}
	}
	return total
}

func withStatus(status int) func(attribute.Set) bool {
	return func(set attribute.Set) bool {
		v, ok := set.Value("status")
		return ok && v.AsInt64() == int64(status)
	}
}

func anyAttrs(attribute.Set) bool { return true }

func TestClientDisconnectIsNotAStorageError_OtherOps(t *testing.T) {
	ctxErr := func(ctx context.Context, op string) error { return fmt.Errorf("%s: %w", op, ctx.Err()) }
	headFails := func(ctx context.Context, _, _ string) (int64, error) { return 0, ctxErr(ctx, "head object") }
	listFails := func(ctx context.Context, _, _ string) ([]storage.BlobInfo, error) {
		return nil, ctxErr(ctx, "list objects")
	}
	getFails := func(ctx context.Context, _, _, _ string) (*storage.S3Object, error) {
		return nil, ctxErr(ctx, "get object")
	}
	checkBucketFails := func(ctx context.Context, _ string) (bool, error) { return false, ctxErr(ctx, "head bucket") }
	createBucketFails := func(ctx context.Context, _ string) error { return ctxErr(ctx, "create bucket") }
	deleteFails := func(ctx context.Context, _, _ string) error { return ctxErr(ctx, "delete object") }
	headOK := func(context.Context, string, string) (int64, error) { return 1, nil }
	v2 := map[string]string{"Accept": ContentTypeResticV2}
	blobPath := "/" + testRepository + "/locks/" + testBlobName
	configPath := "/" + testRepository + "/config"
	createPath := "/" + testRepository + "?create=true"
	for name, tc := range map[string]struct {
		op, method, path string
		headers          map[string]string
		store            *mockStorage
	}{
		"list blobs": {
			"list blobs", http.MethodGet, "/" + testRepository + "/locks/", v2, &mockStorage{listObjectsFn: listFails},
		},
		"delete blob, head fails": {
			"delete blob", http.MethodDelete, blobPath, nil, &mockStorage{headObjectFn: headFails},
		},
		"delete blob, delete fails": {
			"delete blob", http.MethodDelete, blobPath, nil, &mockStorage{headObjectFn: headOK, deleteObjectFn: deleteFails},
		},
		"head config": {
			"head config", http.MethodHead, configPath, nil, &mockStorage{headObjectFn: headFails},
		},
		"get config": {
			"get config", http.MethodGet, configPath, nil, &mockStorage{getObjectFn: getFails},
		},
		"delete config, head fails": {
			"delete config", http.MethodDelete, configPath, nil, &mockStorage{headObjectFn: headFails},
		},
		"delete config, delete fails": {
			"delete config", http.MethodDelete, configPath, nil, &mockStorage{headObjectFn: headOK, deleteObjectFn: deleteFails},
		},
		"create repository, check fails": {
			"create repository", http.MethodPost, createPath, nil, &mockStorage{checkBucketFn: checkBucketFails},
		},
		"create repository, create fails": {
			"create repository", http.MethodPost, createPath, nil, &mockStorage{createBucketFn: createBucketFails},
		},
	} {
		t.Run(name, func(t *testing.T) {
			buf := captureLogOutput(t)
			srv := newTestServer(tc.store)

			rec := doRequestWithContext(t, cancelledContext(), srv, tc.method, tc.path, nil, defaultAuth(), tc.headers)

			if rec.Code != StatusClientClosedRequest {
				t.Fatalf("expected %d, got %d: %s", StatusClientClosedRequest, rec.Code, rec.Body.String())
			}
			assertAbortedAtWarn(t, buf, tc.op)
		})
	}
}

func assertAbortedAtWarn(t *testing.T, buf *bytes.Buffer, op string) {
	t.Helper()
	entries := parseLogLines(t, buf)
	if e := findLog(entries, map[string]any{"level": "error"}); e != nil {
		t.Errorf("client disconnect logged at error level: %v", e)
	}
	if findLog(entries, map[string]any{"level": "warn", "message": op + " aborted: client disconnected"}) == nil {
		t.Errorf("no warn entry for the aborted %s:\n%s", op, buf.String())
	}
}

func TestListBlobs_ClientDisconnectAfterPartialBody(t *testing.T) {
	buf := captureLogOutput(t)
	store := &mockStorage{
		listStreamFn: func(ctx context.Context, _, _ string, fn func(storage.BlobInfo) error) error {
			if err := fn(storage.BlobInfo{Name: "locks/" + testBlobName, Size: 1}); err != nil {
				return err
			}
			return fmt.Errorf("list objects: %w", ctx.Err())
		},
	}
	srv := newTestServer(store)

	defer func() {
		if r := recover(); r != http.ErrAbortHandler {
			t.Errorf("expected panic(http.ErrAbortHandler), got %v", r)
		}
		assertAbortedAtWarn(t, buf, "list blobs")
	}()
	doRequestWithContext(t, cancelledContext(), srv, http.MethodGet, "/"+testRepository+"/locks/", nil, defaultAuth(), map[string]string{
		"Accept": ContentTypeResticV2,
	})
}

type failingWriter struct{ *httptest.ResponseRecorder }

func (f *failingWriter) Write([]byte) (int, error) { return 0, errors.New("write: broken pipe") }

func listOneBlob(context.Context, string, string) ([]storage.BlobInfo, error) {
	return []storage.BlobInfo{{Name: "locks/" + testBlobName, Size: 1}}, nil
}

func listRequest(t *testing.T, ctx context.Context) *http.Request {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/"+testRepository+"/locks/", nil).WithContext(ctx)
	req.Header.Set("Authorization", makeBasicAuth(makeJWT(t, jwt.MapClaims{
		"user": testUser, "repository": testRepository, "writeOnce": false, "exp": jwt.NewNumericDate(time.Now().Add(time.Hour)),
	})))
	req.Header.Set("Accept", ContentTypeResticV2)
	return req
}

func TestListBlobs_ClientDisconnectDuringResponseWrite(t *testing.T) {
	for name, store := range map[string]*mockStorage{
		"empty list": {},
		"flush":      {listObjectsFn: listOneBlob},
	} {
		t.Run(name, func(t *testing.T) {
			buf := captureLogOutput(t)
			srv := newTestServer(store)

			srv.Handler().ServeHTTP(&failingWriter{httptest.NewRecorder()}, listRequest(t, cancelledContext()))

			assertAbortedAtWarn(t, buf, "list blobs")
		})
	}
}

func TestListBlobs_WriteFailureWithLiveClientIsAnError(t *testing.T) {
	for name, tc := range map[string]struct {
		store *mockStorage
		msg   string
	}{
		"empty list": {&mockStorage{}, "failed to write blob list response"},
		"flush":      {&mockStorage{listObjectsFn: listOneBlob}, "failed to flush blob list response"},
	} {
		t.Run(name, func(t *testing.T) {
			buf := captureLogOutput(t)
			srv := newTestServer(tc.store)

			srv.Handler().ServeHTTP(&failingWriter{httptest.NewRecorder()}, listRequest(t, context.Background()))

			entries := parseLogLines(t, buf)
			if findLog(entries, map[string]any{"level": "error", "message": tc.msg}) == nil {
				t.Errorf("no error entry for the write failure:\n%s", buf.String())
			}
			if e := findLog(entries, map[string]any{"message": "list blobs aborted: client disconnected"}); e != nil {
				t.Errorf("write failure with a live client booked as a disconnect: %v", e)
			}
		})
	}
}
