package proxy

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"restic-proxy/internal/client"
	"restic-proxy/internal/meta"
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
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/data/0123", body)
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

	select {
	case status := <-statuses:
		if status != http.StatusBadGateway {
			t.Errorf("expected the interrupted upload to get 502, got %d", status)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the hanging upload was not interrupted")
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
	handler := New(client.New(meta.Api{}), "", false)

	handler.NetworkChanged()
	handler.NetworkChanged()

	if len(handler.upstream.connections) != 0 {
		t.Errorf("expected no tracked connections, got %d", len(handler.upstream.connections))
	}
}

func TestNetworkChanged_InterruptsAPendingGrantLookup(t *testing.T) {
	arrived := make(chan struct{}, 1)
	release := make(chan struct{})
	api := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, request *http.Request) {
		arrived <- struct{}{}
		select {
		case <-request.Context().Done():
		case <-release:
		}
	}))
	t.Cleanup(api.Close)
	t.Cleanup(func() { close(release) })
	handler, proxy := newProxy(t, client.New(meta.Api{Url: api.URL}))

	statuses := uploadInBackground(proxy, strings.NewReader("pack"))
	select {
	case <-arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("the grant lookup never reached the API")
	}

	handler.NetworkChanged()

	select {
	case status := <-statuses:
		if status != http.StatusServiceUnavailable {
			t.Errorf("expected 503, got %d", status)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the grant lookup was not interrupted")
	}
}

func TestReset_CancelsDialsInProgress(t *testing.T) {
	upstream := newUpstream()
	dialing := make(chan struct{})
	upstream.dialContext = func(ctx context.Context, _, _ string) (net.Conn, error) {
		close(dialing)
		<-ctx.Done()
		return nil, context.Cause(ctx)
	}

	failed := make(chan error, 1)
	go func() {
		_, err := upstream.dial(context.Background(), "tcp", "backend:443")
		failed <- err
	}()
	<-dialing
	upstream.reset()

	select {
	case err := <-failed:
		if !errors.Is(err, errNetworkChanged) {
			t.Errorf("expected the dial to fail with the network change, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the dial was not cancelled")
	}
}

func TestReset_RejectsDialsThatCompleteAfterIt(t *testing.T) {
	upstream := newUpstream()
	dialing := make(chan struct{})
	proceed := make(chan struct{})
	local, remote := net.Pipe()
	t.Cleanup(func() { _ = remote.Close() })
	upstream.dialContext = func(context.Context, string, string) (net.Conn, error) {
		close(dialing)
		<-proceed
		return local, nil
	}

	type result struct {
		conn net.Conn
		err  error
	}
	results := make(chan result, 1)
	go func() {
		conn, err := upstream.dial(context.Background(), "tcp", "backend:443")
		results <- result{conn, err}
	}()
	<-dialing
	upstream.reset()
	close(proceed)

	dialed := <-results
	if dialed.conn != nil || !errors.Is(dialed.err, errNetworkChanged) {
		t.Errorf("expected the late dial to be rejected, got %v %v", dialed.conn, dialed.err)
	}
	if len(upstream.connections) != 0 {
		t.Errorf("expected no tracked connections, got %d", len(upstream.connections))
	}
	if _, err := local.Write([]byte("x")); !errors.Is(err, io.ErrClosedPipe) {
		t.Errorf("expected the late connection to be closed, got %v", err)
	}
}

func TestBind_ReleaseWaitsForAnInterruptInProgress(t *testing.T) {
	upstream := newUpstream()
	interrupting := make(chan struct{})
	finish := make(chan struct{})
	_, release := upstream.bind(context.Background(), func() {
		close(interrupting)
		<-finish
	})

	upstream.reset()
	select {
	case <-interrupting:
	case <-time.After(2 * time.Second):
		t.Fatal("the reset never interrupted the request")
	}

	released := make(chan struct{})
	go func() {
		release()
		close(released)
	}()

	select {
	case <-released:
		t.Fatal("released while the interrupt was still running")
	case <-time.After(100 * time.Millisecond):
	}

	close(finish)
	select {
	case <-released:
	case <-time.After(2 * time.Second):
		t.Fatal("release never returned after the interrupt finished")
	}
}

type freezableRelay struct {
	listener net.Listener
	frozen   chan struct{}

	mu    sync.Mutex
	conns []net.Conn
}

func newFreezableRelay(t *testing.T, target string) *freezableRelay {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}

	relay := &freezableRelay{listener: listener, frozen: make(chan struct{})}
	go relay.accept(target)
	t.Cleanup(relay.close)
	return relay
}

func (relay *freezableRelay) accept(target string) {
	for {
		downstream, err := relay.listener.Accept()
		if err != nil {
			return
		}

		upstream, err := net.Dial("tcp", target)
		if err != nil {
			_ = downstream.Close()
			continue
		}

		relay.mu.Lock()
		relay.conns = append(relay.conns, downstream, upstream)
		relay.mu.Unlock()
		go relay.forward(upstream, downstream)
		go relay.forward(downstream, upstream)
	}
}

func (relay *freezableRelay) forward(destination, source net.Conn) {
	buffer := make([]byte, 32<<10)
	for {
		read, err := source.Read(buffer)
		if err != nil {
			_ = destination.Close()
			return
		}

		select {
		case <-relay.frozen:
			return
		default:
		}

		if _, err := destination.Write(buffer[:read]); err != nil {
			return
		}
	}
}

func (relay *freezableRelay) freeze() {
	close(relay.frozen)
}

func (relay *freezableRelay) close() {
	_ = relay.listener.Close()
	relay.mu.Lock()
	defer relay.mu.Unlock()
	for _, conn := range relay.conns {
		_ = conn.Close()
	}
}

const pingedBackendRead = 4

type pingedUpload struct {
	handler  *Handler
	relay    *freezableRelay
	proxy    *httptest.Server
	arrived  chan struct{}
	statuses <-chan int
}

func uploadOverAPingedHTTP2Backend(t *testing.T, backendConfig *http.HTTP2Config, body io.Reader) pingedUpload {
	t.Helper()
	arrived := make(chan struct{}, 1)
	release := make(chan struct{})
	backend := httptest.NewUnstartedServer(http.HandlerFunc(func(_ http.ResponseWriter, request *http.Request) {
		_, _ = io.Copy(io.Discard, io.LimitReader(request.Body, pingedBackendRead))
		arrived <- struct{}{}
		select {
		case <-request.Context().Done():
		case <-release:
		}
	}))
	backend.EnableHTTP2 = true
	backend.Config.HTTP2 = backendConfig
	backend.StartTLS()
	t.Cleanup(backend.Close)
	t.Cleanup(func() { close(release) })

	relay := newFreezableRelay(t, backend.Listener.Addr().String())
	handler, proxy := newProxy(t, newAPI(t, "https://"+relay.listener.Addr().String(), http.StatusCreated, nil))
	handler.upstream.transport.TLSClientConfig = backend.Client().Transport.(*http.Transport).TLSClientConfig.Clone()
	handler.upstream.transport.HTTP2 = &http.HTTP2Config{
		SendPingTimeout: 100 * time.Millisecond,
		PingTimeout:     100 * time.Millisecond,
	}

	upload := pingedUpload{
		handler: handler, relay: relay, proxy: proxy, arrived: arrived, statuses: uploadInBackground(proxy, body),
	}
	select {
	case <-arrived:
	case <-time.After(5 * time.Second):
		t.Fatal("the upload never reached the backend")
	}
	return upload
}

func (upload pingedUpload) expectBadGatewayAfterFreezing(t *testing.T) {
	t.Helper()
	upload.relay.freeze()

	select {
	case status := <-upload.statuses:
		if status != http.StatusBadGateway {
			t.Errorf("expected 502, got %d", status)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the stalled upload outlived the HTTP/2 ping timeout")
	}
}

func TestHTTP2PingFailure_FailsAStalledUploadWithoutANetworkChange(t *testing.T) {
	body, writer := io.Pipe()
	t.Cleanup(func() { _ = writer.Close() })
	go func() { _, _ = writer.Write([]byte("partial pack")) }()

	uploadOverAPingedHTTP2Backend(t, nil, body).expectBadGatewayAfterFreezing(t)
}

func (upload pingedUpload) awaitUploadedBeyond(t *testing.T, bytes int64) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for upload.handler.Uploaded() <= bytes {
		if time.Now().After(deadline) {
			t.Fatalf("the proxy read only %d bytes of the upload, needed more than %d", upload.handler.Uploaded(), bytes)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestHTTP2PingFailure_FailsAnUploadWaitingForFlowControlWhileResticIsStalled(t *testing.T) {
	const window = 64 << 10
	body, writer := io.Pipe()
	t.Cleanup(func() { _ = writer.Close() })
	go func() { _, _ = writer.Write(make([]byte, 2*window)) }()

	upload := uploadOverAPingedHTTP2Backend(t,
		&http.HTTP2Config{MaxReceiveBufferPerStream: window, MaxReceiveBufferPerConnection: window}, body)
	// The backend grants the window plus what it reads, and the transport sends all of one body read before starting
	// the next, so a read past that credit leaves it waiting for flow control rather than reading.
	upload.awaitUploadedBeyond(t, window+pingedBackendRead)

	upload.expectBadGatewayAfterFreezing(t)
}
