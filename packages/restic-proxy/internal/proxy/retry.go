package proxy

import (
	"errors"
	"io"
	"math/rand/v2"
	"net/http"
	"os"
	"regexp"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog/log"
)

var retryBudget = time.Minute
var retryBaseDelay = 500 * time.Millisecond
var retryMaxDelay = 10 * time.Second
var maxReplayBytes int64 = 128 << 20

var contentAddressed = regexp.MustCompile(`/(data|index|keys|locks|snapshots)/[0-9a-f]{64}$`)

var errReplaySuperseded = errors.New("upload replay superseded by a newer attempt")

type retryTransport struct {
	next     http.RoundTripper
	throttle *atomic.Pointer[throttle]
}

func (transport retryTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if bodiless(request) {
		return transport.retry(request, func() *http.Request { return request })
	}

	if !replayableUpload(request) {
		return transport.next.RoundTrip(request)
	}

	upload, err := newReplay(request.Body)
	if err != nil {
		log.Warn().Err(err).Msg("Could not spool an upload for replay, sending it once")
		return transport.next.RoundTrip(request)
	}
	defer upload.discard()

	return transport.retry(request, func() *http.Request {
		attempt := request.Clone(request.Context())
		attempt.Body = upload.attempt(request, transport.throttle)
		return attempt
	})
}

func (transport retryTransport) retry(request *http.Request, attempt func() *http.Request) (*http.Response, error) {
	deadline := time.Now().Add(retryBudget)
	delay := retryBaseDelay

	for count := 1; ; count++ {
		response, err := transport.next.RoundTrip(attempt())
		if !transient(response, err) || request.Context().Err() != nil {
			return response, err
		}

		wait := delay/2 + rand.N(delay/2+1)
		if time.Now().Add(wait).After(deadline) {
			return response, err
		}

		if response != nil {
			_ = response.Body.Close()
		}

		log.Warn().Err(err).Int("attempt", count).Dur("wait", wait).Str("method", request.Method).Str("path", request.URL.Path).Msg("Retrying a transient backend failure")

		timer := time.NewTimer(wait)
		select {
		case <-request.Context().Done():
			timer.Stop()
			return nil, request.Context().Err()
		case <-timer.C:
		}

		delay = min(delay*2, retryMaxDelay)
	}
}

func bodiless(request *http.Request) bool {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		return false
	}

	return request.Body == nil || request.Body == http.NoBody
}

// michael stores these objects with If-None-Match and accepts a re-upload of
// identical content, so replaying one after a lost response is safe.
func replayableUpload(request *http.Request) bool {
	return request.Method == http.MethodPost &&
		request.ContentLength > 0 &&
		request.ContentLength <= maxReplayBytes &&
		contentAddressed.MatchString(request.URL.Path)
}

func transient(response *http.Response, err error) bool {
	if err != nil {
		return true
	}

	switch response.StatusCode {
	case http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return true
	default:
		return false
	}
}

type replay struct {
	mutex    sync.Mutex
	source   io.ReadCloser
	spool    *os.File
	spooled  int64
	attempts int
}

func newReplay(source io.ReadCloser) (*replay, error) {
	spool, err := os.CreateTemp("", "restic-proxy-upload-*")
	if err != nil {
		return nil, err
	}

	return &replay{source: source, spool: spool}, nil
}

func (upload *replay) attempt(request *http.Request, current *atomic.Pointer[throttle]) io.ReadCloser {
	upload.mutex.Lock()
	defer upload.mutex.Unlock()

	upload.attempts++
	sent := pace(request.Context(), io.NopCloser(io.NewSectionReader(upload.spool, 0, upload.spooled)), current)
	return io.NopCloser(io.MultiReader(sent, &replayTail{upload: upload, attempt: upload.attempts}))
}

func (upload *replay) discard() {
	upload.mutex.Lock()
	defer upload.mutex.Unlock()

	upload.attempts++
	_ = upload.source.Close()
	_ = upload.spool.Close()
	_ = os.Remove(upload.spool.Name())
}

type replayTail struct {
	upload  *replay
	attempt int
}

func (tail *replayTail) Read(buffer []byte) (int, error) {
	upload := tail.upload
	upload.mutex.Lock()
	defer upload.mutex.Unlock()

	if tail.attempt != upload.attempts {
		return 0, errReplaySuperseded
	}

	read, err := upload.source.Read(buffer)
	if read > 0 {
		if _, spoolErr := upload.spool.WriteAt(buffer[:read], upload.spooled); spoolErr != nil {
			return 0, spoolErr
		}
		upload.spooled += int64(read)
	}

	return read, err
}
