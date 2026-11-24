package proxy

import (
	"errors"
	"io"
	"net/http"
	"sync"
)

type interruptible struct {
	body      io.ReadCloser
	interrupt func()

	mu        sync.Mutex
	reading   bool
	finished  bool
	abandoned bool
	retired   bool
}

func (reader *interruptible) Read(buffer []byte) (int, error) {
	reader.mu.Lock()
	if reader.abandoned {
		reader.mu.Unlock()
		return 0, http.ErrBodyReadAfterClose
	}
	reader.reading = true
	reader.mu.Unlock()

	read, err := reader.body.Read(buffer)

	reader.mu.Lock()
	reader.reading = false
	reader.finished = reader.finished || errors.Is(err, io.EOF)
	reader.mu.Unlock()
	return read, err
}

// A transport aborting a stream (e.g. after a lost HTTP/2 ping) closes the body and waits for Close. The server's
// body Close would wait for a pending Read, which only an interrupt releases, and then drain what restic has yet to
// send, so an unfinished body is left for the server to close once the handler is done. Interrupting only a pending
// Read keeps early backend replies, which also close the body, intact more often.
func (reader *interruptible) Close() error {
	reader.mu.Lock()
	if reader.finished || reader.retired {
		reader.mu.Unlock()
		return reader.body.Close()
	}
	defer reader.mu.Unlock()
	reader.abandoned = true
	if reader.reading {
		reader.interrupt()
	}
	return nil
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
