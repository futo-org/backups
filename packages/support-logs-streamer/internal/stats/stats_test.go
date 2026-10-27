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
	received map[string][]report
	applied  map[string]Delta
	seen     map[string]bool
	secrets  []string
	respond  func(w http.ResponseWriter, r *http.Request) bool
}

func newFakeAPI(status int) (*fakeAPI, *httptest.Server) {
	api := &fakeAPI{status: status, received: map[string][]report{}, applied: map[string]Delta{}, seen: map[string]bool{}}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var rep report
		_ = json.NewDecoder(r.Body).Decode(&rep)

		api.mu.Lock()
		api.received[r.URL.Path] = append(api.received[r.URL.Path], rep)
		api.secrets = append(api.secrets, r.Header.Get("X-Internal-Secret"))
		status := api.status
		if status == http.StatusNoContent && !api.seen[rep.ID] {
			api.seen[rep.ID] = true
			current := api.applied[r.URL.Path]
			current.merge(rep.Delta)
			api.applied[r.URL.Path] = current
		}
		respond := api.respond
		api.mu.Unlock()

		if respond != nil && respond(w, r) {
			return
		}
		w.WriteHeader(status)
	}))
	return api, server
}

const s1 = "/internal/support-logs/sessions/s1/stats"

func TestFlushSendsIncrements(t *testing.T) {
	api, server := newFakeAPI(http.StatusNoContent)
	defer server.Close()

	tracker := NewTracker(server.URL+"/", "secret")
	at := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	tracker.Record("s1", Delta{Lines: 10, Bytes: 100, Batches: 1, DroppedLines: 2, LastBatchAt: at})
	tracker.Record("s1", Delta{Lines: 5, Bytes: 50, Batches: 1, LastBatchAt: at.Add(time.Second), Finished: true})
	tracker.Flush(context.Background())

	got := api.received[s1]
	if len(got) != 1 {
		t.Fatalf("expected one report, got %d", len(got))
	}
	if got[0].ID == "" {
		t.Error("report carries no reportId")
	}
	want := Delta{Lines: 15, Bytes: 150, Batches: 2, DroppedLines: 2, LastBatchAt: at.Add(time.Second), Finished: true}
	if !got[0].LastBatchAt.Equal(want.LastBatchAt) {
		t.Errorf("lastBatchAt %v, want %v", got[0].LastBatchAt, want.LastBatchAt)
	}
	got[0].LastBatchAt = want.LastBatchAt
	if got[0].Delta != want {
		t.Errorf("got %+v, want %+v", got[0].Delta, want)
	}
	if api.secrets[0] != "secret" {
		t.Errorf("internal secret not sent")
	}

	tracker.Flush(context.Background())
	if len(api.received[s1]) != 1 {
		t.Error("an already reported delta was sent again")
	}
}

func TestFlushRetriesFailuresUnderTheSameReportID(t *testing.T) {
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
	tracker.Flush(context.Background())

	got := api.received[s1]
	if len(got) != 3 {
		t.Fatalf("expected the failed report, its retry and the newer delta, got %+v", got)
	}
	if got[1].ID != got[0].ID || got[1].Delta != got[0].Delta {
		t.Errorf("retry changed the report: %+v then %+v", got[0], got[1])
	}
	if got[2].ID == got[0].ID || got[2].Lines != 2 {
		t.Errorf("newer delta was merged into the retried report: %+v", got[2])
	}
	if applied := api.applied[s1]; applied.Lines != 3 || applied.Batches != 2 {
		t.Errorf("applied %+v", applied)
	}
}

func TestRetryAfterLostResponseCountsOnce(t *testing.T) {
	api, server := newFakeAPI(http.StatusNoContent)
	defer server.Close()

	var once sync.Once
	api.respond = func(w http.ResponseWriter, r *http.Request) bool {
		lost := false
		once.Do(func() { lost = true })
		if lost {
			hijacked, _, _ := w.(http.Hijacker).Hijack()
			_ = hijacked.Close()
		}
		return lost
	}

	tracker := NewTracker(server.URL, "secret")
	tracker.Record("s1", Delta{Lines: 7, Batches: 1, Finished: true})
	tracker.Flush(context.Background())
	tracker.Flush(context.Background())

	got := api.received[s1]
	if len(got) != 2 || got[0].ID != got[1].ID {
		t.Fatalf("expected one retry under the same reportId, got %+v", got)
	}
	if applied := api.applied[s1]; applied.Lines != 7 || applied.Batches != 1 {
		t.Errorf("a report applied before its response was lost was counted again: %+v", applied)
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

func TestWaitJoinsAsyncReportsAndKeepsFailuresForTheFinalFlush(t *testing.T) {
	api, server := newFakeAPI(http.StatusServiceUnavailable)
	defer server.Close()

	release := make(chan struct{})
	var blocked sync.Once
	api.respond = func(w http.ResponseWriter, r *http.Request) bool {
		blocked.Do(func() { <-release })
		return false
	}

	tracker := NewTracker(server.URL, "secret")
	tracker.Record("s1", Delta{Lines: 4, Batches: 1, Finished: true})
	tracker.FlushSessionAsync(context.Background(), "s1")

	waited := make(chan struct{})
	go func() {
		tracker.Wait()
		close(waited)
	}()

	select {
	case <-waited:
		t.Fatal("Wait returned while a report was still in flight")
	case <-time.After(100 * time.Millisecond):
	}

	close(release)
	<-waited

	api.mu.Lock()
	api.status = http.StatusNoContent
	api.mu.Unlock()
	tracker.Flush(context.Background())

	got := api.received[s1]
	if len(got) != 2 || got[1].ID != got[0].ID {
		t.Fatalf("final flush did not resend the failed report: %+v", got)
	}
	if applied := api.applied[s1]; applied.Lines != 4 || !applied.Finished {
		t.Errorf("applied %+v", applied)
	}
}

func TestRunSettlesItsReportBeforeReturning(t *testing.T) {
	api, server := newFakeAPI(http.StatusNoContent)
	defer server.Close()

	started := make(chan struct{})
	var first sync.Once
	api.respond = func(w http.ResponseWriter, r *http.Request) bool {
		hold := false
		first.Do(func() { hold = true })
		if hold {
			close(started)
			<-r.Context().Done()
			return true
		}
		return false
	}

	tracker := NewTracker(server.URL, "secret")
	tracker.Record("s1", Delta{Lines: 9, Batches: 1})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		tracker.Run(ctx, 10*time.Millisecond)
	}()

	<-started
	cancel()
	<-done
	tracker.Flush(context.Background())

	got := api.received[s1]
	if len(got) != 2 || got[0].ID != got[1].ID {
		t.Fatalf("the canceled report was not resent by the final flush: %+v", got)
	}
}
