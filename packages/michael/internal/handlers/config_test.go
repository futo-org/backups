package handlers

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"

	"michael/internal/storage"

	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

func TestCheckConfig_Found(t *testing.T) {
	store := &mockStorage{
		headObjectFn: func(_ context.Context, _, key string) (int64, error) {
			if key == "config" {
				return 42, nil
			}
			return 0, errors.New("not found")
		},
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodHead, "/"+testRepository+"/config", nil, defaultAuth(), nil)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
	if cl := rec.Header().Get("Content-Length"); cl != "42" {
		t.Errorf("expected Content-Length 42, got %s", cl)
	}
}

func TestCheckConfig_NotFound(t *testing.T) {
	store := &mockStorage{
		headObjectFn: func(_ context.Context, _, _ string) (int64, error) {
			return 0, &types.NotFound{}
		},
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodHead, "/"+testRepository+"/config", nil, defaultAuth(), nil)

	if rec.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d", rec.Code)
	}
}

func TestGetConfig_Success(t *testing.T) {
	store := &mockStorage{
		getObjectFn: func(_ context.Context, _, key, _ string) (*storage.S3Object, error) {
			return &storage.S3Object{
				Body:          io.NopCloser(strings.NewReader("config-data")),
				ContentLength: 11,
				ContentType:   "application/octet-stream",
				ETag:          `"abc123"`,
			}, nil
		},
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodGet, "/"+testRepository+"/config", nil, defaultAuth(), nil)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rec.Code)
	}
	if rec.Body.String() != "config-data" {
		t.Errorf("unexpected body: %s", rec.Body.String())
	}
	if rec.Header().Get("ETag") != `"abc123"` {
		t.Errorf("unexpected ETag: %s", rec.Header().Get("ETag"))
	}
}

func TestGetConfig_NotFound(t *testing.T) {
	store := &mockStorage{
		getObjectFn: func(_ context.Context, _, _, _ string) (*storage.S3Object, error) {
			return nil, &types.NoSuchKey{}
		},
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodGet, "/"+testRepository+"/config", nil, defaultAuth(), nil)

	if rec.Code != http.StatusNotFound {
		t.Errorf("expected 404, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestGetConfig_IfNoneMatch304(t *testing.T) {
	store := &mockStorage{
		getObjectFn: func(_ context.Context, _, _, _ string) (*storage.S3Object, error) {
			return &storage.S3Object{
				Body:          io.NopCloser(strings.NewReader("config-data")),
				ContentLength: 11,
				ETag:          `"abc123"`,
			}, nil
		},
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodGet, "/"+testRepository+"/config", nil, defaultAuth(), map[string]string{
		"If-None-Match": `"abc123"`,
	})

	if rec.Code != http.StatusNotModified {
		t.Errorf("expected 304, got %d", rec.Code)
	}
}

func TestSaveConfig_Success(t *testing.T) {
	var capturedWriteOnce bool
	store := &mockStorage{
		putObjectFn: func(_ context.Context, _, _ string, _ io.Reader, _ int64, writeOnce bool, _ string) error {
			capturedWriteOnce = writeOnce
			return nil
		},
	}
	srv := newTestServer(store)
	body := strings.NewReader("new-config")
	rec := doRequest(t, srv, http.MethodPost, "/"+testRepository+"/config", body, defaultAuth(), nil)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if capturedWriteOnce {
		t.Error("expected writeOnce to be false for non-WORM auth")
	}
}

func TestSaveConfig_WORMConflict(t *testing.T) {
	store := &mockStorage{
		putObjectFn: func(_ context.Context, _, _ string, _ io.Reader, _ int64, _ bool, _ string) error {
			return storage.ErrPreconditionFailed
		},
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodPost, "/"+testRepository+"/config", strings.NewReader("data"), wormAuth(), nil)

	if rec.Code != http.StatusForbidden {
		t.Errorf("expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDeleteConfig_Success(t *testing.T) {
	store := &mockStorage{
		headObjectFn:   func(_ context.Context, _, _ string) (int64, error) { return 100, nil },
		deleteObjectFn: func(_ context.Context, _, _ string) error { return nil },
	}
	srv := newTestServer(store)
	rec := doRequest(t, srv, http.MethodDelete, "/"+testRepository+"/config", nil, defaultAuth(), nil)

	if rec.Code != http.StatusOK {
		t.Errorf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestDeleteConfig_WORMForbidden(t *testing.T) {
	srv := newTestServer(&mockStorage{})
	rec := doRequest(t, srv, http.MethodDelete, "/"+testRepository+"/config", nil, wormAuth(), nil)

	if rec.Code != http.StatusForbidden {
		t.Errorf("expected 403, got %d", rec.Code)
	}
}

func TestSaveConfig_ClientDisconnectIsNotAStorageError(t *testing.T) {
	buf := captureLogOutput(t)
	store := &mockStorage{
		putObjectFn: func(ctx context.Context, _, _ string, body io.Reader, _ int64, _ bool, _ string) error {
			_, _ = io.Copy(io.Discard, body)
			return fmt.Errorf("put object: %w", ctx.Err())
		},
	}
	srv := newTestServer(store)

	rec := doRequestWithContext(t, cancelledContext(), srv, http.MethodPost, "/"+testRepository+"/config", strings.NewReader("{}"), defaultAuth(), nil)

	if rec.Code != StatusClientClosedRequest {
		t.Fatalf("expected %d, got %d: %s", StatusClientClosedRequest, rec.Code, rec.Body.String())
	}
	entries := parseLogLines(t, buf)
	if e := findLog(entries, map[string]any{"level": "error"}); e != nil {
		t.Errorf("client disconnect logged at error level: %v", e)
	}
	if findLog(entries, map[string]any{"level": "warn", "message": "save config aborted: client disconnected"}) == nil {
		t.Errorf("no warn entry for the aborted config save:\n%s", buf.String())
	}
}
