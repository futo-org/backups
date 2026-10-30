package proxy

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type roundTripperFunc func(*http.Request) (*http.Response, error)

func (fn roundTripperFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

func newFlakyBackend(t *testing.T, failures int64, fail func(http.ResponseWriter)) (*httptest.Server, *atomic.Int64) {
	t.Helper()
	var hits atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		if hits.Add(1) <= failures {
			fail(writer)
			return
		}
		writer.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(server.Close)
	return server, &hits
}

func roundTrip(t *testing.T, method string, url string, body string) (*http.Response, error) {
	t.Helper()
	var request *http.Request
	var err error
	if body == "" {
		request, err = http.NewRequest(method, url, nil)
	} else {
		request, err = http.NewRequest(method, url, strings.NewReader(body))
	}
	if err != nil {
		t.Fatalf("new request: %v", err)
	}

	response, err := retryTransport{next: newTransport(), throttle: &atomic.Pointer[throttle]{}}.RoundTrip(request)
	if response != nil {
		t.Cleanup(func() { response.Body.Close() })
	}
	return response, err
}

func TestRetry_BadGatewayThenSuccess(t *testing.T) {
	backend, hits := newFlakyBackend(t, 2, func(writer http.ResponseWriter) { writer.WriteHeader(http.StatusBadGateway) })

	response, err := roundTrip(t, http.MethodGet, backend.URL+"/data/abc", "")

	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", response.StatusCode)
	}
	if hits.Load() != 3 {
		t.Errorf("expected 3 attempts, got %d", hits.Load())
	}
}

func TestRetry_ConnectionResetThenSuccess(t *testing.T) {
	backend, hits := newFlakyBackend(t, 1, func(writer http.ResponseWriter) {
		connection, _, err := http.NewResponseController(writer).Hijack()
		if err == nil {
			_ = connection.Close()
		}
	})

	response, err := roundTrip(t, http.MethodHead, backend.URL+"/config", "")

	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", response.StatusCode)
	}
	if hits.Load() != 2 {
		t.Errorf("expected 2 attempts, got %d", hits.Load())
	}
}

func TestRetry_TimeoutThenSuccess(t *testing.T) {
	var attempts atomic.Int64
	transport := retryTransport{next: roundTripperFunc(func(request *http.Request) (*http.Response, error) {
		if attempts.Add(1) == 1 {
			return nil, os.ErrDeadlineExceeded
		}
		return &http.Response{StatusCode: http.StatusOK, Body: http.NoBody, Request: request}, nil
	})}

	request := httptest.NewRequest(http.MethodGet, "http://backend.test/keys/abc", nil)
	response, err := transport.RoundTrip(request)

	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", response.StatusCode)
	}
	if attempts.Load() != 2 {
		t.Errorf("expected 2 attempts, got %d", attempts.Load())
	}
}

func TestRetry_GivesUpAfterBudget(t *testing.T) {
	backend, hits := newFlakyBackend(t, 1000, func(writer http.ResponseWriter) { writer.WriteHeader(http.StatusServiceUnavailable) })

	started := time.Now()
	response, err := roundTrip(t, http.MethodGet, backend.URL+"/data/abc", "")

	if err != nil {
		t.Fatalf("expected the last response, got %v", err)
	}
	if response.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("expected 503, got %d", response.StatusCode)
	}
	if hits.Load() < 2 {
		t.Errorf("expected several attempts, got %d", hits.Load())
	}
	if elapsed := time.Since(started); elapsed > retryBudget+time.Second {
		t.Errorf("expected to give up within the budget, took %s", elapsed)
	}
}

func TestRetry_DoesNotReplayArbitraryWrites(t *testing.T) {
	backend, hits := newFlakyBackend(t, 1, func(writer http.ResponseWriter) { writer.WriteHeader(http.StatusBadGateway) })

	response, err := roundTrip(t, http.MethodPost, backend.URL+"/config", "config")

	if err != nil {
		t.Fatalf("expected a response, got %v", err)
	}
	if response.StatusCode != http.StatusBadGateway {
		t.Errorf("expected 502, got %d", response.StatusCode)
	}
	if hits.Load() != 1 {
		t.Errorf("expected a single attempt, got %d", hits.Load())
	}
}

func TestRetry_ClientErrorsAreFinal(t *testing.T) {
	backend, hits := newFlakyBackend(t, 1, func(writer http.ResponseWriter) { writer.WriteHeader(http.StatusNotFound) })

	response, err := roundTrip(t, http.MethodGet, backend.URL+"/data/abc", "")

	if err != nil {
		t.Fatalf("expected a response, got %v", err)
	}
	if response.StatusCode != http.StatusNotFound {
		t.Errorf("expected 404, got %d", response.StatusCode)
	}
	if hits.Load() != 1 {
		t.Errorf("expected a single attempt, got %d", hits.Load())
	}
}

func TestRetry_StopsWhenCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var attempts atomic.Int64
	transport := retryTransport{next: roundTripperFunc(func(*http.Request) (*http.Response, error) {
		attempts.Add(1)
		cancel()
		return nil, errors.New("connection reset by peer")
	})}

	request := httptest.NewRequestWithContext(ctx, http.MethodGet, "http://backend.test/config", nil)
	_, err := transport.RoundTrip(request)

	if err == nil {
		t.Fatal("expected an error")
	}
	if attempts.Load() != 1 {
		t.Errorf("expected a single attempt, got %d", attempts.Load())
	}
}

func TestRetry_StalledErrorBodyDoesNotBlockTheNextAttempt(t *testing.T) {
	release := make(chan struct{})
	backend, hits := newFlakyBackend(t, 1, func(writer http.ResponseWriter) {
		writer.WriteHeader(http.StatusServiceUnavailable)
		_, _ = writer.Write([]byte("partial"))
		_ = http.NewResponseController(writer).Flush()
		<-release
	})
	t.Cleanup(func() { close(release) })

	started := time.Now()
	response, err := roundTrip(t, http.MethodGet, backend.URL+"/data/abc", "")

	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", response.StatusCode)
	}
	if hits.Load() != 2 {
		t.Errorf("expected 2 attempts, got %d", hits.Load())
	}
	if elapsed := time.Since(started); elapsed > retryBudget {
		t.Errorf("expected the stalled body to be abandoned, took %s", elapsed)
	}
}

const testBlobName = "4f9d2c7e1b0a8f6e5d4c3b2a1908f7e6d5c4b3a291807f6e5d4c3b2a19080706"

type recordedUploads struct {
	mutex  sync.Mutex
	bodies [][]byte
}

func (uploads *recordedUploads) add(body []byte) int {
	uploads.mutex.Lock()
	defer uploads.mutex.Unlock()
	uploads.bodies = append(uploads.bodies, body)
	return len(uploads.bodies)
}

func newUploadBackend(t *testing.T, respond func(attempt int, uploads *recordedUploads, writer http.ResponseWriter, request *http.Request) bool) (*httptest.Server, *recordedUploads) {
	t.Helper()
	uploads := &recordedUploads{}
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		uploads.mutex.Lock()
		attempt := len(uploads.bodies) + 1
		uploads.mutex.Unlock()
		if respond(attempt, uploads, writer, request) {
			return
		}

		body, err := io.ReadAll(request.Body)
		if err != nil {
			t.Errorf("read upload: %v", err)
		}
		uploads.add(body)
		writer.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(server.Close)
	return server, uploads
}

func uploadPayload() string {
	return strings.Repeat("restic pack bytes ", 64<<10)
}

func TestRetry_ReplaysContentAddressedUploads(t *testing.T) {
	spool := t.TempDir()
	t.Setenv("TMPDIR", spool)
	backend, uploads := newUploadBackend(t, func(attempt int, uploads *recordedUploads, writer http.ResponseWriter, request *http.Request) bool {
		if attempt > 2 {
			return false
		}
		body, _ := io.ReadAll(request.Body)
		uploads.add(body)
		writer.WriteHeader(http.StatusBadGateway)
		return true
	})
	payload := uploadPayload()

	response, err := roundTrip(t, http.MethodPost, backend.URL+"/repository/data/"+testBlobName, payload)

	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", response.StatusCode)
	}
	if len(uploads.bodies) != 3 {
		t.Fatalf("expected 3 attempts, got %d", len(uploads.bodies))
	}
	for attempt, body := range uploads.bodies {
		if string(body) != payload {
			t.Errorf("attempt %d sent %d bytes that differ from the %d byte upload", attempt+1, len(body), len(payload))
		}
	}
	if leftovers, _ := os.ReadDir(spool); len(leftovers) != 0 {
		t.Errorf("expected the spooled upload to be removed, found %d files", len(leftovers))
	}
}

func TestRetry_ReplaysAnUploadCutOffMidway(t *testing.T) {
	backend, uploads := newUploadBackend(t, func(attempt int, uploads *recordedUploads, writer http.ResponseWriter, request *http.Request) bool {
		if attempt > 1 {
			return false
		}
		partial := make([]byte, 100<<10)
		_, _ = io.ReadFull(request.Body, partial)
		uploads.add(partial)
		connection, _, err := http.NewResponseController(writer).Hijack()
		if err == nil {
			_ = connection.Close()
		}
		return true
	})
	payload := uploadPayload()

	response, err := roundTrip(t, http.MethodPost, backend.URL+"/repository/index/"+testBlobName, payload)

	if err != nil {
		t.Fatalf("expected success, got %v", err)
	}
	if response.StatusCode != http.StatusOK {
		t.Errorf("expected 200, got %d", response.StatusCode)
	}
	if len(uploads.bodies) != 2 || string(uploads.bodies[1]) != payload {
		t.Errorf("expected the second attempt to carry the whole upload, got %d attempts", len(uploads.bodies))
	}
}

func TestRetry_DoesNotReplayOversizedUploads(t *testing.T) {
	previous := maxReplayBytes
	maxReplayBytes = 1024
	t.Cleanup(func() { maxReplayBytes = previous })
	backend, hits := newFlakyBackend(t, 1, func(writer http.ResponseWriter) { writer.WriteHeader(http.StatusBadGateway) })

	response, err := roundTrip(t, http.MethodPost, backend.URL+"/repository/data/"+testBlobName, uploadPayload())

	if err != nil {
		t.Fatalf("expected a response, got %v", err)
	}
	if response.StatusCode != http.StatusBadGateway {
		t.Errorf("expected 502, got %d", response.StatusCode)
	}
	if hits.Load() != 1 {
		t.Errorf("expected a single attempt, got %d", hits.Load())
	}
}
