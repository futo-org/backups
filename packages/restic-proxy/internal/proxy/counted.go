package proxy

import (
	"io"
	"net/http"
	"sync/atomic"
)

type counted struct {
	io.ReadCloser
	total *atomic.Int64
}

func count(body io.ReadCloser, total *atomic.Int64) io.ReadCloser {
	if body == nil || body == http.NoBody {
		return body
	}

	return counted{ReadCloser: body, total: total}
}

func (reader counted) Read(buffer []byte) (int, error) {
	read, err := reader.ReadCloser.Read(buffer)
	if read > 0 {
		reader.total.Add(int64(read))
	}

	return read, err
}
