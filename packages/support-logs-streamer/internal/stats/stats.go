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

	"github.com/google/uuid"
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

type report struct {
	ID string `json:"reportId"`
	Delta
}

type sessionState struct {
	pending    Delta
	hasPending bool
	inflight   *report
	sending    bool
}

func (s *sessionState) idle() bool {
	return !s.hasPending && s.inflight == nil && !s.sending
}

// Tracker aggregates per-session counters and reports them to yucca-api as
// increments, so any number of replicas can serve the same session. A report
// keeps its ID across retries and yucca-api applies each ID once, so a report
// whose response was lost is never counted twice; anything recorded while it
// is outstanding waits for the next report instead of joining it.
type Tracker struct {
	endpoint string
	secret   string
	client   *http.Client

	mu       sync.Mutex
	sessions map[string]*sessionState
	async    sync.WaitGroup
}

func NewTracker(yuccaAPIURL, internalSecret string) *Tracker {
	return &Tracker{
		endpoint: strings.TrimSuffix(yuccaAPIURL, "/") + "/internal/support-logs/sessions/",
		secret:   internalSecret,
		client:   &http.Client{Timeout: 10 * time.Second},
		sessions: make(map[string]*sessionState),
	}
}

func (t *Tracker) Record(session string, delta Delta) {
	t.mu.Lock()
	defer t.mu.Unlock()
	state, ok := t.sessions[session]
	if !ok {
		state = &sessionState{}
		t.sessions[session] = state
	}
	state.pending.merge(delta)
	state.hasPending = true
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

// FlushSessionAsync reports a session in the background; Wait joins every such
// report, so shutdown can finish them before its final Flush.
func (t *Tracker) FlushSessionAsync(ctx context.Context, session string) {
	t.async.Add(1)
	go func() {
		defer t.async.Done()
		t.FlushSession(ctx, session)
	}()
}

func (t *Tracker) Wait() {
	t.async.Wait()
}

func (t *Tracker) next(session string) *report {
	t.mu.Lock()
	defer t.mu.Unlock()
	state, ok := t.sessions[session]
	if !ok || state.sending {
		return nil
	}
	if state.inflight == nil {
		if !state.hasPending {
			return nil
		}
		state.inflight = &report{ID: uuid.NewString(), Delta: state.pending}
		state.pending = Delta{}
		state.hasPending = false
	}
	state.sending = true
	return state.inflight
}

func (t *Tracker) settle(session string, acknowledged, unknown bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	state := t.sessions[session]
	state.sending = false
	switch {
	case unknown:
		delete(t.sessions, session)
		return
	case acknowledged:
		state.inflight = nil
	}
	if state.idle() {
		delete(t.sessions, session)
	}
}

// FlushSession reports a session until it has nothing left to send: a retried
// report can be followed by increments recorded while it was outstanding, and
// shutdown flushes only once. A failed report stays in flight under the same
// ID for the next flush; a 404 means yucca-api has no such session, and
// retrying would only grow the backlog.
func (t *Tracker) FlushSession(ctx context.Context, session string) {
	for ctx.Err() == nil {
		r := t.next(session)
		if r == nil {
			return
		}

		status, err := t.post(ctx, session, *r)
		switch {
		case err == nil && status == http.StatusNoContent:
			t.settle(session, true, false)
		case err == nil && status == http.StatusNotFound:
			log.Warn().Str("support_session", session).Msg("yucca-api does not know this support session; dropping its stats")
			t.settle(session, false, true)
			return
		default:
			log.Warn().Err(err).Int("status", status).Str("support_session", session).Msg("failed to report support session stats; will retry")
			t.settle(session, false, false)
			return
		}
	}
}

func (t *Tracker) post(ctx context.Context, session string, r report) (int, error) {
	body, err := json.Marshal(r)
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
