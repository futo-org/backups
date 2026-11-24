package proxy

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestCount_LeavesMissingBodiesAlone(t *testing.T) {
	var total atomic.Int64

	if count(nil, &total) != nil {
		t.Error("expected a nil body to stay nil")
	}
	if count(http.NoBody, &total) != http.NoBody {
		t.Error("expected http.NoBody to stay http.NoBody so the transport still sees an empty body")
	}
}

func TestCount_AddsEveryByteRead(t *testing.T) {
	var total atomic.Int64
	total.Store(10)

	read, err := io.ReadAll(count(io.NopCloser(bytes.NewReader(make([]byte, 5000))), &total))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if len(read) != 5000 {
		t.Fatalf("expected 5000 bytes, got %d", len(read))
	}
	if total.Load() != 5010 {
		t.Errorf("expected the total to grow by 5000 to 5010, got %d", total.Load())
	}
}

func TestCount_OnlyCountsWhatThePacedBodyLetsThrough(t *testing.T) {
	const bytesPerSec = 200_000

	current := throttled(t, bytesPerSec, "")
	burst := current.Load().limiter.Burst()
	payload := bytes.Repeat([]byte("x"), 3*burst)

	var total atomic.Int64
	done := make(chan error, 1)
	started := time.Now()
	go func() {
		_, err := io.ReadAll(count(newPaced(t.Context(), io.NopCloser(bytes.NewReader(payload)), current), &total))
		done <- err
	}()

	time.Sleep(50 * time.Millisecond)
	early := total.Load()
	allowed := int64(burst) + int64(time.Since(started).Seconds()*bytesPerSec) + int64(burst)
	if early >= int64(len(payload)) || early > allowed {
		t.Errorf("expected at most %d bytes counted while paced, got %d of %d", allowed, early, len(payload))
	}

	if err := <-done; err != nil {
		t.Fatalf("read: %v", err)
	}
	if total.Load() != int64(len(payload)) {
		t.Errorf("expected %d bytes counted, got %d", len(payload), total.Load())
	}
}

func TestServeHTTP_CountsUploadedRequestBodies(t *testing.T) {
	received := make(chan int, 2)
	backend := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		body, _ := io.ReadAll(request.Body)
		received <- len(body)
		writer.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(backend.Close)

	handler, proxy := newProxy(t, newAPI(t, backend.URL, http.StatusCreated, nil))
	if err := handler.Throttle(64<<20, ""); err != nil {
		t.Fatalf("throttle: %v", err)
	}

	payload := bytes.Repeat([]byte("p"), 3<<20)
	request, err := http.NewRequest(http.MethodPost, proxy.URL+"/data/abc123", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	request.SetBasicAuth(testRepository, testToken)
	response, err := proxy.Client().Do(request)
	if err != nil {
		t.Fatalf("upload: %v", err)
	}
	response.Body.Close()

	do(t, proxy, "/config", testRepository, testToken)

	if got := <-received; got != len(payload) {
		t.Fatalf("expected the backend to receive %d bytes, got %d", len(payload), got)
	}
	if handler.Uploaded() != int64(len(payload)) {
		t.Errorf("expected %d uploaded bytes, got %d", len(payload), handler.Uploaded())
	}
}
