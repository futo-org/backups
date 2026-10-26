package handlers

import (
	"context"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"

	"michael/internal/auth"
	"michael/internal/httputil"
	"michael/internal/metrics"
	"michael/internal/storage"

	"github.com/rs/zerolog/hlog"
)

const (
	ContentTypeBinary   = "application/octet-stream"
	ContentTypeResticV2 = "application/vnd.x.restic.rest.v2"
)

var validBlobTypes = map[string]bool{
	"data": true, "index": true, "keys": true, "locks": true, "snapshots": true,
}

const StatusClientClosedRequest = 499

var sha256HexPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

var writeError = httputil.WriteError

// net/http cancels the request context on a connection or body-read failure,
// while the storage call may surface the body's EOF before context.Canceled.
// A deadline is the server giving up, not the client leaving.
func clientGone(r *http.Request) bool { return errors.Is(r.Context().Err(), context.Canceled) }

func abortIfClientGone(w http.ResponseWriter, r *http.Request, err error, msg string) bool {
	if !clientGone(r) {
		return false
	}
	hlog.FromRequest(r).Warn().Err(err).Msg(msg)
	writeStorageError(w, r, err)
	return true
}

func logStorageFailure(r *http.Request, err error, abortedMsg, failedMsg string) {
	if clientGone(r) {
		hlog.FromRequest(r).Warn().Err(err).Msg(abortedMsg)
		return
	}
	hlog.FromRequest(r).Error().Err(err).Msg(failedMsg)
}

// writeStorageError maps a storage-layer failure onto the restic contract
// (docs/restic-retries.md): a client that hung up gets 499, a shedding pool
// answers 503 + Retry-After, which restic retries with backoff, and anything
// else stays the generic 500.
func writeStorageError(w http.ResponseWriter, r *http.Request, err error) {
	if clientGone(r) {
		writeError(w, r, StatusClientClosedRequest, "Client closed request")
		return
	}
	if errors.Is(err, storage.ErrBackendsUnavailable) {
		w.Header().Set("Retry-After", "30")
		writeError(w, r, http.StatusServiceUnavailable, "Storage temporarily unavailable")
		return
	}
	writeError(w, r, http.StatusInternalServerError, "An error occurred with the storage server")
}

func (s *Server) respondWithS3Object(w http.ResponseWriter, r *http.Request, obj *storage.S3Object) {
	defer obj.Body.Close()

	// If-None-Match → 304
	if etag := r.Header.Get("If-None-Match"); etag != "" && etag == obj.ETag {
		w.WriteHeader(http.StatusNotModified)
		return
	}

	if obj.ETag != "" {
		w.Header().Set("ETag", obj.ETag)
	}

	ct := obj.ContentType
	if ct == "" {
		ct = ContentTypeBinary
	}
	w.Header().Set("Content-Type", ct)

	if obj.ContentRange != "" {
		w.Header().Set("Content-Range", obj.ContentRange)
	}

	if obj.ContentLength > 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(obj.ContentLength, 10))
	}

	// Range → 206
	rangeHeader := r.Header.Get("Range")
	if rangeHeader != "" && rangeHeader != "bytes=0-" {
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.WriteHeader(http.StatusOK)
	}

	if s.Metrics != nil && obj.ContentLength > 0 {
		a := auth.FromContext(r.Context())
		s.Metrics.RequestedBytes.Add(r.Context(), obj.ContentLength, metrics.BlobMetricOption(a, metrics.BlobType(r)))
	}

	if _, err := io.Copy(w, obj.Body); err != nil {
		hlog.FromRequest(r).Error().Err(err).Msg("error streaming response")
	}
}
