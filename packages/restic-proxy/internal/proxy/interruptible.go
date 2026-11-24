package proxy

import (
	"io"
	"net/http"
	"sync"
)

type interruptible struct {
	body      io.ReadCloser
	interrupt func()

	mu      sync.Mutex
	reading bool
	retired bool
}

func (reader *interruptible) Read(buffer []byte) (int, error) {
	reader.mu.Lock()
	reader.reading = true
	reader.mu.Unlock()

	read, err := reader.body.Read(buffer)

	reader.mu.Lock()
	reader.reading = false
	reader.mu.Unlock()
	return read, err
}

// A transport aborting a stream (e.g. after a lost HTTP/2 ping) closes the body from another goroutine, but the
// server's body Close waits for the pending Read, which only an interrupt releases.
func (reader *interruptible) Close() error {
	reader.mu.Lock()
	if reader.reading && !reader.retired {
		reader.interrupt()
	}
	reader.mu.Unlock()
	return reader.body.Close()
}

func (reader *interruptible) retire() {
	reader.mu.Lock()
	reader.retired = true
	reader.mu.Unlock()
}

func interruptOnClose(request *http.Request, interrupt func()) (retire func()) {
	if request.Body == nil || request.Body == http.NoBody {
		return func() {}
	}

	body := &interruptible{body: request.Body, interrupt: interrupt}
	request.Body = body
	return body.retire
}
