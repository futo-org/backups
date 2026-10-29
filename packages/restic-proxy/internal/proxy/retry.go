package proxy

import (
	"io"
	"math/rand/v2"
	"net/http"
	"time"

	"github.com/rs/zerolog/log"
)

var retryBudget = time.Minute
var retryBaseDelay = 500 * time.Millisecond
var retryMaxDelay = 10 * time.Second

type retryTransport struct {
	next http.RoundTripper
}

func (transport retryTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if !replayable(request) {
		return transport.next.RoundTrip(request)
	}

	deadline := time.Now().Add(retryBudget)
	delay := retryBaseDelay

	for attempt := 1; ; attempt++ {
		response, err := transport.next.RoundTrip(request)
		if !transient(response, err) || request.Context().Err() != nil {
			return response, err
		}

		wait := delay/2 + rand.N(delay/2+1)
		if time.Now().Add(wait).After(deadline) {
			return response, err
		}

		if response != nil {
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
		}

		log.Warn().Err(err).Int("attempt", attempt).Dur("wait", wait).Str("path", request.URL.Path).Msg("Retrying a transient backend failure")

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

func replayable(request *http.Request) bool {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		return false
	}

	return request.Body == nil || request.Body == http.NoBody
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
