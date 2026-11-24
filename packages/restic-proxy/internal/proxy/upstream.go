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
	transport   *http.Transport
	dialContext func(context.Context, string, string) (net.Conn, error)

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
		dialContext: (&net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}).DialContext,
		generation:  generation,
		cancel:      cancel,
		connections: map[*trackedConn]struct{}{},
	}
	u.transport = newTransport(u.dial)
	return u
}

func (u *upstream) current() context.Context {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.generation
}

func (u *upstream) dial(ctx context.Context, network, address string) (net.Conn, error) {
	generation := u.current()
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	stop := context.AfterFunc(generation, func() { cancel(context.Cause(generation)) })
	defer stop()

	conn, err := u.dialContext(ctx, network, address)
	if err != nil {
		return nil, err
	}

	u.mu.Lock()
	defer u.mu.Unlock()
	if u.generation != generation {
		_ = conn.Close()
		return nil, errNetworkChanged
	}

	tracked := &trackedConn{Conn: conn, release: u.forget}
	u.connections[tracked] = struct{}{}
	return tracked, nil
}

func (u *upstream) forget(conn *trackedConn) {
	u.mu.Lock()
	delete(u.connections, conn)
	u.mu.Unlock()
}

func (u *upstream) bind(parent context.Context, interrupt func()) (context.Context, context.CancelFunc) {
	generation := u.current()
	ctx, cancel := context.WithCancelCause(parent)
	interrupted := make(chan struct{})
	stop := context.AfterFunc(generation, func() {
		defer close(interrupted)
		cancel(context.Cause(generation))
		interrupt()
	})
	return ctx, func() {
		if !stop() {
			<-interrupted
		}
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
