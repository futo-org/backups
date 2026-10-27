package stats

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

type fakeAPI struct {
	mu       sync.Mutex
	status   int
	received map[string][]Delta
	secrets  []string
}

func newFakeAPI(status int) (*fakeAPI, *httptest.Server) {
	api := &fakeAPI{status: status, received: map[string][]Delta{}}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		api.mu.Lock()
		defer api.mu.Unlock()
		var delta Delta
		_ = json.NewDecoder(r.Body).Decode(&delta)
		api.received[r.URL.Path] = append(api.received[r.URL.Path], delta)
		api.secrets = append(api.secrets, r.Header.Get("X-Internal-Secret"))
		w.WriteHeader(api.status)
	}))
	return api, server
}

func TestFlushSendsIncrements(t *testing.T) {
	api, server := newFakeAPI(http.StatusNoContent)
	defer server.Close()

	tracker := NewTracker(server.URL+"/", "secret")
	at := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	tracker.Record("s1", Delta{Lines: 10, Bytes: 100, Batches: 1, DroppedLines: 2, LastBatchAt: at})
	tracker.Record("s1", Delta{Lines: 5, Bytes: 50, Batches: 1, LastBatchAt: at.Add(time.Second), Finished: true})
	tracker.Flush(context.Background())

	got := api.received["/internal/support-logs/sessions/s1/stats"]
	if len(got) != 1 {
		t.Fatalf("expected one report, got %d", len(got))
	}
	want := Delta{Lines: 15, Bytes: 150, Batches: 2, DroppedLines: 2, LastBatchAt: at.Add(time.Second), Finished: true}
	if !got[0].LastBatchAt.Equal(want.LastBatchAt) {
		t.Errorf("lastBatchAt %v, want %v", got[0].LastBatchAt, want.LastBatchAt)
	}
	got[0].LastBatchAt = want.LastBatchAt
	if got[0] != want {
		t.Errorf("got %+v, want %+v", got[0], want)
	}
	if api.secrets[0] != "secret" {
		t.Errorf("internal secret not sent")
	}

	tracker.Flush(context.Background())
	if len(api.received["/internal/support-logs/sessions/s1/stats"]) != 1 {
		t.Error("an already reported delta was sent again")
	}
}

func TestFlushRetriesFailures(t *testing.T) {
	api, server := newFakeAPI(http.StatusBadGateway)
	defer server.Close()

	tracker := NewTracker(server.URL, "secret")
	tracker.Record("s1", Delta{Lines: 1, Batches: 1})
	tracker.Flush(context.Background())

	api.mu.Lock()
	api.status = http.StatusNoContent
	api.mu.Unlock()

	tracker.Record("s1", Delta{Lines: 2, Batches: 1})
	tracker.Flush(context.Background())

	got := api.received["/internal/support-logs/sessions/s1/stats"]
	if len(got) != 2 || got[1].Lines != 3 || got[1].Batches != 2 {
		t.Fatalf("failed delta was not retried: %+v", got)
	}
}

func TestFlushDropsUnknownSessions(t *testing.T) {
	api, server := newFakeAPI(http.StatusNotFound)
	defer server.Close()

	tracker := NewTracker(server.URL, "secret")
	tracker.Record("gone", Delta{Lines: 1})
	tracker.Flush(context.Background())
	tracker.Flush(context.Background())

	if n := len(api.received["/internal/support-logs/sessions/gone/stats"]); n != 1 {
		t.Fatalf("expected a single attempt for an unknown session, got %d", n)
	}
}
