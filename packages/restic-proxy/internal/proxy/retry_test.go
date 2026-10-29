package proxy

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
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

	response, err := retryTransport{next: newTransport()}.RoundTrip(request)
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

func TestRetry_DoesNotReplayUploads(t *testing.T) {
	backend, hits := newFlakyBackend(t, 1, func(writer http.ResponseWriter) { writer.WriteHeader(http.StatusBadGateway) })

	response, err := roundTrip(t, http.MethodPost, backend.URL+"/data/abc", "pack")

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
