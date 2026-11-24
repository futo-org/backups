package proxy

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"restic-proxy/internal/client"
)

type hangingBackend struct {
	server      *httptest.Server
	hangs       atomic.Bool
	arrived     chan struct{}
	release     chan struct{}
	connections atomic.Int64
}

func newHangingBackend(t *testing.T) *hangingBackend {
	t.Helper()
	backend := &hangingBackend{arrived: make(chan struct{}, 8), release: make(chan struct{})}
	backend.hangs.Store(true)
	backend.server = httptest.NewUnstartedServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		_, _ = io.Copy(io.Discard, io.LimitReader(request.Body, 4))
		if backend.hangs.Load() {
			backend.arrived <- struct{}{}
			<-backend.release
			return
		}

		_, _ = io.Copy(io.Discard, request.Body)
		writer.WriteHeader(http.StatusOK)
	}))
	backend.server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			backend.connections.Add(1)
		}
	}
	backend.server.Start()
	t.Cleanup(func() {
		close(backend.release)
		backend.server.Close()
	})
	return backend
}

func upload(server *httptest.Server, body io.Reader) (int, error) {
	request, err := http.NewRequest(http.MethodPost, server.URL+"/data/0123", body)
	if err != nil {
		return 0, err
	}
	request.SetBasicAuth(testRepository, testToken)

	response, err := server.Client().Do(request)
	if err != nil {
		return 0, err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)
	return response.StatusCode, nil
}

func uploadInBackground(server *httptest.Server, body io.Reader) <-chan int {
	statuses := make(chan int, 1)
	go func() {
		status, _ := upload(server, body)
		statuses <- status
	}()
	return statuses
}

func awaitArrival(t *testing.T, backend *hangingBackend) {
	t.Helper()
	select {
	case <-backend.arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("the upload never reached the backend")
	}
}

func TestNetworkChanged_FailsHangingUploadsAsRetryable(t *testing.T) {
	backend := newHangingBackend(t)
	handler, proxy := newProxy(t, newAPI(t, backend.server.URL, http.StatusCreated, nil))

	body, writer := io.Pipe()
	t.Cleanup(func() { _ = writer.Close() })
	go func() { _, _ = writer.Write([]byte("partial pack")) }()

	statuses := uploadInBackground(proxy, body)
	awaitArrival(t, backend)

	select {
	case <-statuses:
		t.Fatal("the upload finished while the backend was hanging")
	case <-time.After(100 * time.Millisecond):
	}

	started := time.Now()
	handler.NetworkChanged()

	select {
	case status := <-statuses:
		if status != http.StatusBadGateway {
			t.Errorf("expected 502, got %d", status)
		}
		if elapsed := time.Since(started); elapsed > time.Second {
			t.Errorf("expected the upload to fail promptly, took %s", elapsed)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the hanging upload was not interrupted")
	}
}

func TestNetworkChanged_RetriesSucceedOverAFreshConnection(t *testing.T) {
	backend := newHangingBackend(t)
	handler, proxy := newProxy(t, newAPI(t, backend.server.URL, http.StatusCreated, nil))

	statuses := uploadInBackground(proxy, strings.NewReader("pack"))
	awaitArrival(t, backend)

	backend.hangs.Store(false)
	handler.NetworkChanged()

	if status := <-statuses; status != http.StatusBadGateway {
		t.Errorf("expected the interrupted upload to get 502, got %d", status)
	}

	status, err := upload(proxy, strings.NewReader("pack"))
	if err != nil {
		t.Fatalf("retry: %v", err)
	}
	if status != http.StatusOK {
		t.Errorf("expected the retry to succeed, got %d", status)
	}
	if backend.connections.Load() != 2 {
		t.Errorf("expected the retry on a new connection, saw %d connections", backend.connections.Load())
	}
}

func TestNetworkChanged_DropsIdleConnections(t *testing.T) {
	backend := newHangingBackend(t)
	backend.hangs.Store(false)
	handler, proxy := newProxy(t, newAPI(t, backend.server.URL, http.StatusCreated, nil))

	for range 2 {
		if status, err := upload(proxy, strings.NewReader("pack")); err != nil || status != http.StatusOK {
			t.Fatalf("upload: %d %v", status, err)
		}
	}
	if backend.connections.Load() != 1 {
		t.Fatalf("expected the idle connection to be reused, saw %d connections", backend.connections.Load())
	}

	handler.NetworkChanged()

	if status, err := upload(proxy, strings.NewReader("pack")); err != nil || status != http.StatusOK {
		t.Fatalf("upload after the change: %d %v", status, err)
	}
	if backend.connections.Load() != 2 {
		t.Errorf("expected a fresh connection after the change, saw %d connections", backend.connections.Load())
	}
}

func TestNetworkChanged_FailsStreamsOnABusyHTTP2Connection(t *testing.T) {
	arrived := make(chan struct{}, 1)
	release := make(chan struct{})
	var connections atomic.Int64
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/hang" {
			arrived <- struct{}{}
			<-release
		}
		writer.WriteHeader(http.StatusOK)
	}))
	server.EnableHTTP2 = true
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			connections.Add(1)
		}
	}
	server.StartTLS()
	t.Cleanup(func() {
		close(release)
		server.Close()
	})

	upstream := newUpstream()
	upstream.transport.TLSClientConfig = server.Client().Transport.(*http.Transport).TLSClientConfig.Clone()
	httpClient := &http.Client{Transport: upstream.transport}

	failed := make(chan error, 1)
	go func() {
		ctx, done := upstream.bind(t.Context(), func() {})
		defer done()
		request, _ := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+"/hang", nil)
		response, err := httpClient.Do(request)
		if err == nil {
			_ = response.Body.Close()
		}
		failed <- err
	}()

	select {
	case <-arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("the request never reached the server")
	}

	upstream.reset()

	select {
	case err := <-failed:
		if err == nil {
			t.Error("expected the hanging stream to fail")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the hanging stream was not interrupted")
	}

	response, err := httpClient.Get(server.URL + "/ok")
	if err != nil {
		t.Fatalf("request after the change: %v", err)
	}
	_ = response.Body.Close()

	if response.ProtoMajor != 2 {
		t.Errorf("expected HTTP/2, got %s", response.Proto)
	}
	if connections.Load() != 2 {
		t.Errorf("expected a fresh HTTP/2 connection after the change, saw %d connections", connections.Load())
	}
}

func TestNetworkChanged_WithoutTrafficIsHarmless(t *testing.T) {
	handler := New(client.Client{}, "", false)

	handler.NetworkChanged()
	handler.NetworkChanged()

	if len(handler.upstream.connections) != 0 {
		t.Errorf("expected no tracked connections, got %d", len(handler.upstream.connections))
	}
}
