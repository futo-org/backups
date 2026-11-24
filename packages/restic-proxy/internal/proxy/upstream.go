package proxy

import (
	"context"
	"errors"
	"net"
	"net/http"
	"sync"
	"time"
)

var errNetworkChanged = errors.New("network changed")

type upstream struct {
	transport *http.Transport
	dialer    *net.Dialer

	mu          sync.Mutex
	generation  context.Context
	cancel      context.CancelCauseFunc
	connections map[*trackedConn]struct{}
}

type trackedConn struct {
	net.Conn
	once    sync.Once
	release func(*trackedConn)
}

func (conn *trackedConn) Close() error {
	conn.once.Do(func() { conn.release(conn) })
	return conn.Conn.Close()
}

func newUpstream() *upstream {
	generation, cancel := context.WithCancelCause(context.Background())
	u := &upstream{
		dialer:      &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second},
		generation:  generation,
		cancel:      cancel,
		connections: map[*trackedConn]struct{}{},
	}
	u.transport = newTransport(u.dial)
	return u
}

func (u *upstream) dial(ctx context.Context, network, address string) (net.Conn, error) {
	conn, err := u.dialer.DialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}

	tracked := &trackedConn{Conn: conn, release: u.forget}
	u.mu.Lock()
	u.connections[tracked] = struct{}{}
	u.mu.Unlock()
	return tracked, nil
}

func (u *upstream) forget(conn *trackedConn) {
	u.mu.Lock()
	delete(u.connections, conn)
	u.mu.Unlock()
}

func (u *upstream) bind(parent context.Context, interrupt func()) (context.Context, context.CancelFunc) {
	u.mu.Lock()
	generation := u.generation
	u.mu.Unlock()

	ctx, cancel := context.WithCancelCause(parent)
	stop := context.AfterFunc(generation, func() {
		cancel(context.Cause(generation))
		interrupt()
	})
	return ctx, func() {
		stop()
		cancel(nil)
	}
}

func (u *upstream) reset() int {
	u.mu.Lock()
	cancel := u.cancel
	connections := u.connections
	u.generation, u.cancel = context.WithCancelCause(context.Background())
	u.connections = map[*trackedConn]struct{}{}
	u.mu.Unlock()

	cancel(errNetworkChanged)
	for conn := range connections {
		_ = conn.Conn.Close()
	}
	u.transport.CloseIdleConnections()
	return len(connections)
}

func newTransport(dial func(context.Context, string, string) (net.Conn, error)) *http.Transport {
	return &http.Transport{
		Proxy:                 http.ProxyFromEnvironment,
		DialContext:           dial,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          32,
		MaxIdleConnsPerHost:   32,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: time.Second,
		DisableCompression:    true,
		HTTP2: &http.HTTP2Config{
			SendPingTimeout: 15 * time.Second,
			PingTimeout:     10 * time.Second,
		},
	}
}
