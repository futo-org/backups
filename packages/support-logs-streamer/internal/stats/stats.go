package stats

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/rs/zerolog/log"
)

type Delta struct {
	Lines        int64     `json:"lines"`
	Bytes        int64     `json:"bytes"`
	Batches      int64     `json:"batches"`
	DroppedLines int64     `json:"droppedLines"`
	LastBatchAt  time.Time `json:"lastBatchAt"`
	Finished     bool      `json:"finished"`
}

func (d *Delta) merge(other Delta) {
	d.Lines += other.Lines
	d.Bytes += other.Bytes
	d.Batches += other.Batches
	d.DroppedLines += other.DroppedLines
	if other.LastBatchAt.After(d.LastBatchAt) {
		d.LastBatchAt = other.LastBatchAt
	}
	d.Finished = d.Finished || other.Finished
}

// Tracker aggregates per-session counters and reports them to yucca-api as
// increments, so any number of replicas can serve the same session.
type Tracker struct {
	endpoint string
	secret   string
	client   *http.Client

	mu       sync.Mutex
	sessions map[string]Delta
}

func NewTracker(yuccaAPIURL, internalSecret string) *Tracker {
	return &Tracker{
		endpoint: strings.TrimSuffix(yuccaAPIURL, "/") + "/internal/support-logs/sessions/",
		secret:   internalSecret,
		client:   &http.Client{Timeout: 10 * time.Second},
		sessions: make(map[string]Delta),
	}
}

func (t *Tracker) Record(session string, delta Delta) {
	t.mu.Lock()
	defer t.mu.Unlock()
	current := t.sessions[session]
	current.merge(delta)
	t.sessions[session] = current
}

func (t *Tracker) take(session string) (Delta, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	delta, ok := t.sessions[session]
	delete(t.sessions, session)
	return delta, ok
}

func (t *Tracker) sessionIDs() []string {
	t.mu.Lock()
	defer t.mu.Unlock()
	ids := make([]string, 0, len(t.sessions))
	for id := range t.sessions {
		ids = append(ids, id)
	}
	return ids
}

func (t *Tracker) Flush(ctx context.Context) {
	for _, session := range t.sessionIDs() {
		t.FlushSession(ctx, session)
	}
}

// FlushSession reports one session's pending increments. A failed report is
// merged back so the next flush retries it; a 404 means yucca-api has no such
// session, and retrying would only grow the backlog.
func (t *Tracker) FlushSession(ctx context.Context, session string) {
	delta, ok := t.take(session)
	if !ok {
		return
	}

	status, err := t.post(ctx, session, delta)
	switch {
	case err == nil && status == http.StatusNoContent:
	case err == nil && status == http.StatusNotFound:
		log.Warn().Str("support_session", session).Msg("yucca-api does not know this support session; dropping its stats")
	default:
		log.Warn().Err(err).Int("status", status).Str("support_session", session).Msg("failed to report support session stats; will retry")
		t.Record(session, delta)
	}
}

func (t *Tracker) post(ctx context.Context, session string, delta Delta) (int, error) {
	body, err := json.Marshal(delta)
	if err != nil {
		return 0, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, t.endpoint+url.PathEscape(session)+"/stats", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Internal-Secret", t.secret)

	resp, err := t.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
		return resp.StatusCode, fmt.Errorf("unexpected status %d", resp.StatusCode)
	}
	return resp.StatusCode, nil
}

func (t *Tracker) Run(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			t.Flush(ctx)
		}
	}
}
