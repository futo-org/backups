package worker

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"columbo/internal/agent"
	"columbo/internal/bot"
	"columbo/internal/ticket"
)

func ticketInvestigation() agent.Investigation {
	return agent.Investigation{TicketThreadID: "ticket-1", StaffThreadID: "staff-1", DiscordUserID: "owner-1", UserID: "user-1", Description: "opening"}
}

func startTicketPool(t *testing.T, investigator Investigator, client *bot.Client, options Options, workers int) *Pool {
	t.Helper()
	pool := NewPool(investigator, client, time.Second, workers, options)
	ctx, cancel := context.WithCancel(context.Background())
	pool.Run(ctx, workers)
	t.Cleanup(func() { cancel(); pool.Wait() })
	return pool
}

func awaitInvestigation(t *testing.T, calls <-chan agent.Investigation) agent.Investigation {
	t.Helper()
	select {
	case inv := <-calls:
		return inv
	case <-time.After(3 * time.Second):
		t.Fatal("investigation did not start")
		return agent.Investigation{}
	}
}

func assertNoInvestigation(t *testing.T, calls <-chan agent.Investigation, duration time.Duration) {
	t.Helper()
	select {
	case inv := <-calls:
		t.Fatalf("unexpected investigation: %+v", inv)
	case <-time.After(duration):
	}
}

func waitForQueued(t *testing.T, pool *Pool, threadID string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		pool.mu.Lock()
		job := pool.automatic[threadID]
		queued := job != nil && job.queued
		pool.mu.Unlock()
		if queued {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("ticket was not queued")
}

func TestOwnerActivityResetsQuietPeriodAndIgnoresOtherEvents(t *testing.T) {
	calls := make(chan agent.Investigation, 1)
	pool := startTicketPool(t, &fakeInvestigator{triage: func(_ context.Context, inv agent.Investigation) (bool, string, error) {
		calls <- inv
		return false, "", context.Canceled
	}}, nil, Options{TicketQuietPeriod: 200 * time.Millisecond}, 1)
	inv := ticketInvestigation()
	if !pool.Enqueue(inv) {
		t.Fatal("enqueue failed")
	}
	time.Sleep(100 * time.Millisecond)
	pool.RecordActivity(inv.TicketThreadID, ticket.Activity{AuthorID: "owner-1", MessageID: "100"})
	pool.mu.Lock()
	due := pool.automatic[inv.TicketThreadID].due
	pool.mu.Unlock()
	for _, activity := range []ticket.Activity{{AuthorID: "other", MessageID: "101"}, {AuthorID: "owner-1", MessageID: "100"}, {AuthorID: "owner-1", MessageID: "99"}, {AuthorID: "owner-1", MessageID: "bad"}} {
		pool.RecordActivity(inv.TicketThreadID, activity)
	}
	pool.RecordActivity("unknown", ticket.Activity{AuthorID: "owner-1", MessageID: "102"})
	pool.mu.Lock()
	unchanged := pool.automatic[inv.TicketThreadID].due.Equal(due)
	pool.mu.Unlock()
	if !unchanged {
		t.Fatal("ignored activity reset the timer")
	}
	assertNoInvestigation(t, calls, 140*time.Millisecond)
	awaitInvestigation(t, calls)
}

func TestActivityResetsAnAutomaticTicketAlreadyQueuedBehindAnotherJob(t *testing.T) {
	calls := make(chan agent.Investigation, 2)
	release := make(chan struct{})
	pool := startTicketPool(t, &fakeInvestigator{
		investigate: func(ctx context.Context, inv agent.Investigation) (agent.Outcome, error) {
			calls <- inv
			select {
			case <-release:
			case <-ctx.Done():
			}
			return agent.Outcome{}, context.Canceled
		},
		triage: func(_ context.Context, inv agent.Investigation) (bool, string, error) {
			calls <- inv
			return false, "", context.Canceled
		},
	}, nil, Options{TicketQuietPeriod: 150 * time.Millisecond}, 1)
	staff := ticketInvestigation()
	staff.TicketThreadID = "blocking"
	staff.RequestedBy = "staff"
	if !pool.Enqueue(staff) {
		t.Fatal("enqueue staff failed")
	}
	awaitInvestigation(t, calls)
	inv := ticketInvestigation()
	if !pool.Enqueue(inv) {
		t.Fatal("enqueue ticket failed")
	}
	waitForQueued(t, pool, inv.TicketThreadID)
	pool.RecordActivity(inv.TicketThreadID, ticket.Activity{AuthorID: inv.DiscordUserID, MessageID: "123"})
	close(release)
	assertNoInvestigation(t, calls, 90*time.Millisecond)
	if got := awaitInvestigation(t, calls); got.TicketThreadID != inv.TicketThreadID {
		t.Fatalf("wrong ticket: %+v", got)
	}
}

func TestStaffRequestSupersedesPendingAutomaticWithoutWaiting(t *testing.T) {
	calls := make(chan agent.Investigation, 2)
	pool := startTicketPool(t, &fakeInvestigator{
		triage: func(context.Context, agent.Investigation) (bool, string, error) {
			t.Error("superseded automatic ran")
			return false, "", context.Canceled
		},
		investigate: func(_ context.Context, inv agent.Investigation) (agent.Outcome, error) {
			calls <- inv
			return agent.Outcome{}, context.Canceled
		},
	}, nil, Options{TicketQuietPeriod: time.Hour}, 1)
	inv := ticketInvestigation()
	if !pool.Enqueue(inv) {
		t.Fatal("enqueue failed")
	}
	inv.RequestedBy = "staff"
	inv.Prompt = "new evidence"
	if !pool.Enqueue(inv) {
		t.Fatal("staff enqueue failed")
	}
	got := awaitInvestigation(t, calls)
	if got.RequestedBy != "staff" || got.Prompt != "new evidence" {
		t.Fatalf("wrong request: %+v", got)
	}
	pool.mu.Lock()
	pending := len(pool.automatic)
	pool.mu.Unlock()
	if pending != 0 {
		t.Fatal("superseded automatic is retained")
	}
}

func TestStaffRequestCancelsRunningAutomaticAndSuppressesStaleNote(t *testing.T) {
	calls := make(chan agent.Investigation, 2)
	posted := make(chan string, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var note struct {
			Content string `json:"content"`
		}
		_ = json.NewDecoder(r.Body).Decode(&note)
		posted <- note.Content
		w.WriteHeader(204)
	}))
	defer srv.Close()
	pool := startTicketPool(t, &fakeInvestigator{
		triage: func(context.Context, agent.Investigation) (bool, string, error) { return true, "", nil },
		investigate: func(ctx context.Context, inv agent.Investigation) (agent.Outcome, error) {
			calls <- inv
			if inv.RequestedBy == "" {
				<-ctx.Done()
				return agent.Outcome{Note: "stale automatic"}, nil
			}
			return agent.Outcome{Note: "manual result"}, nil
		},
	}, bot.NewClient(srv.URL, "secret"), Options{}, 2)
	inv := ticketInvestigation()
	pool.Enqueue(inv)
	awaitInvestigation(t, calls)
	inv.RequestedBy = "staff"
	if !pool.Enqueue(inv) {
		t.Fatal("staff enqueue failed")
	}
	awaitInvestigation(t, calls)
	select {
	case note := <-posted:
		if len(note) < 13 || note[:13] != "manual result" {
			t.Fatalf("stale note posted: %s", note)
		}
	case <-time.After(time.Second):
		t.Fatal("manual note missing")
	}
	select {
	case note := <-posted:
		t.Fatalf("extra note: %s", note)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestPendingTicketsAreBoundedAndShutdownDoesNotWaitForTimers(t *testing.T) {
	pool := NewPool(&fakeInvestigator{investigate: func(context.Context, agent.Investigation) (agent.Outcome, error) {
		return agent.Outcome{}, context.Canceled
	}}, nil, time.Second, 1, Options{TicketQuietPeriod: time.Hour})
	ctx, cancel := context.WithCancel(context.Background())
	pool.Run(ctx, 1)
	for i := range queueSize {
		inv := ticketInvestigation()
		inv.TicketThreadID = time.Unix(int64(i), 0).String()
		if !pool.Enqueue(inv) {
			t.Fatalf("enqueue %d rejected", i)
		}
	}
	inv := ticketInvestigation()
	if pool.Enqueue(inv) {
		t.Fatal("pending capacity was exceeded")
	}
	inv.TicketThreadID = time.Unix(0, 0).String()
	inv.RequestedBy = "staff"
	if !pool.Enqueue(inv) {
		t.Fatal("staff could not replace a pending automatic at capacity")
	}
	cancel()
	done := make(chan struct{})
	go func() { pool.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("shutdown waited for quiet timers")
	}
	if pool.Enqueue(ticketInvestigation()) {
		t.Fatal("enqueue accepted after shutdown")
	}
}

func TestFreshContextExtendsQuietPeriodAndReachesTriage(t *testing.T) {
	calls := make(chan agent.Investigation, 1)
	var requests atomic.Int32
	started := time.Now()
	newest := started.Add(80 * time.Millisecond).UTC().Format(time.RFC3339Nano)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		_ = json.NewEncoder(w).Encode(ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "owner-1", Messages: []ticket.Message{{ID: "321", AuthorID: "owner-1", Content: "new followup", CreatedAt: newest}}})
	}))
	defer srv.Close()
	pool := startTicketPool(t, &fakeInvestigator{triage: func(_ context.Context, inv agent.Investigation) (bool, string, error) {
		calls <- inv
		return false, "", context.Canceled
	}}, bot.NewClient(srv.URL, "secret"), Options{TicketQuietPeriod: 100 * time.Millisecond, FetchTicketContext: true}, 1)
	pool.Enqueue(ticketInvestigation())
	got := awaitInvestigation(t, calls)
	if time.Since(started) < 180*time.Millisecond || requests.Load() != 2 {
		t.Fatalf("quiet period not extended: elapsed=%s requests=%d", time.Since(started), requests.Load())
	}
	if len(got.Messages) != 1 || got.Messages[0].Content != "new followup" {
		t.Fatalf("fresh messages missing: %+v", got)
	}
}

func TestOwnerMessagesDuringContextFetchDoNotRestartOrDelayTheInvestigation(t *testing.T) {
	calls := make(chan agent.Investigation, 1)
	started := make(chan struct{}, 1)
	release := make(chan struct{})
	var requests atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		started <- struct{}{}
		<-release
		_ = json.NewEncoder(w).Encode(ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "owner-1", Messages: []ticket.Message{{ID: "321", AuthorID: "owner-1", Content: "arrived during context fetch", CreatedAt: time.Now().UTC().Format(time.RFC3339Nano)}}})
	}))
	defer srv.Close()
	pool := startTicketPool(t, &fakeInvestigator{triage: func(_ context.Context, inv agent.Investigation) (bool, string, error) {
		calls <- inv
		return false, "", context.Canceled
	}}, bot.NewClient(srv.URL, "secret"), Options{TicketQuietPeriod: 50 * time.Millisecond, FetchTicketContext: true}, 1)
	inv := ticketInvestigation()
	pool.Enqueue(inv)
	select {
	case <-started:
	case <-time.After(time.Second):
		t.Fatal("context fetch did not start")
	}
	pool.RecordActivity(inv.TicketThreadID, ticket.Activity{AuthorID: inv.DiscordUserID, MessageID: "321"})
	close(release)
	got := awaitInvestigation(t, calls)
	if requests.Load() != 1 || len(got.Messages) != 1 || got.Messages[0].Content != "arrived during context fetch" {
		t.Fatalf("fetches=%d context=%+v", requests.Load(), got.Messages)
	}
	assertNoInvestigation(t, calls, 100*time.Millisecond)
}

func TestStaffRequestUsesFreshContextImmediately(t *testing.T) {
	calls := make(chan agent.Investigation, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "owner-1", Messages: []ticket.Message{{ID: "321", AuthorID: "owner-1", Content: "new", CreatedAt: time.Now().UTC().Format(time.RFC3339Nano)}}})
	}))
	defer srv.Close()
	pool := startTicketPool(t, &fakeInvestigator{investigate: func(_ context.Context, inv agent.Investigation) (agent.Outcome, error) {
		calls <- inv
		return agent.Outcome{}, context.Canceled
	}}, bot.NewClient(srv.URL, "secret"), Options{TicketQuietPeriod: time.Hour, FetchTicketContext: true}, 1)
	inv := ticketInvestigation()
	inv.RequestedBy = "staff"
	pool.Enqueue(inv)
	if got := awaitInvestigation(t, calls); len(got.Messages) != 1 {
		t.Fatalf("fresh context missing: %+v", got)
	}
}

func TestUnavailableFreshContextIsRetriedAndReportedWithoutStaleInvestigation(t *testing.T) {
	var attempts atomic.Int32
	posted := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet {
			attempts.Add(1)
			w.WriteHeader(503)
			return
		}
		var note struct {
			Content string `json:"content"`
		}
		_ = json.NewDecoder(r.Body).Decode(&note)
		posted <- note.Content
		w.WriteHeader(204)
	}))
	defer srv.Close()
	pool := startTicketPool(t, &fakeInvestigator{triage: func(context.Context, agent.Investigation) (bool, string, error) {
		t.Error("triaged stale context")
		return false, "", context.Canceled
	}}, bot.NewClient(srv.URL, "secret"), Options{FetchTicketContext: true}, 1)
	pool.Enqueue(ticketInvestigation())
	select {
	case note := <-posted:
		if note == "" || attempts.Load() != 3 {
			t.Fatalf("note=%s attempts=%d", note, attempts.Load())
		}
	case <-time.After(4 * time.Second):
		t.Fatal("context failure was not reported")
	}
}

func TestClosedAndMismatchedTicketContextNeverReachModel(t *testing.T) {
	for _, test := range []struct {
		name    string
		context ticket.Context
	}{
		{"closed", ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "owner-1", Closed: true}},
		{"wrong ticket", ticket.Context{TicketThreadID: "other", DiscordUserID: "owner-1"}},
		{"wrong owner", ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "other"}},
		{"missing message identity", ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "owner-1", Messages: []ticket.Message{{ID: "123"}}}},
	} {
		t.Run(test.name, func(t *testing.T) {
			posted := make(chan struct{}, 1)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodGet {
					_ = json.NewEncoder(w).Encode(test.context)
					return
				}
				posted <- struct{}{}
				w.WriteHeader(204)
			}))
			t.Cleanup(srv.Close)
			pool := startTicketPool(t, &fakeInvestigator{triage: func(context.Context, agent.Investigation) (bool, string, error) {
				t.Error("invalid/closed context reached triage")
				return false, "", context.Canceled
			}}, bot.NewClient(srv.URL, "secret"), Options{FetchTicketContext: true}, 1)
			pool.Enqueue(ticketInvestigation())
			deadline := time.Now().Add(time.Second)
			for {
				pool.mu.Lock()
				pending := len(pool.jobs)
				pool.mu.Unlock()
				if pending == 0 {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("ticket was not completed")
				}
				time.Sleep(time.Millisecond)
			}
			if test.context.Closed {
				select {
				case <-posted:
					t.Fatal("closed ticket received a note")
				default:
				}
			} else {
				select {
				case <-posted:
				default:
					t.Fatal("invalid context was not reported")
				}
			}
		})
	}
}

type preparingInvestigator struct {
	*fakeInvestigator
	prepare func(context.Context, agent.Investigation) agent.Investigation
}

func (f preparingInvestigator) Prepare(ctx context.Context, inv agent.Investigation) agent.Investigation {
	return f.prepare(ctx, inv)
}

func TestFreshContextIsPreparedOnceBeforeTriageAndInvestigation(t *testing.T) {
	calls := make(chan agent.Investigation, 1)
	var prepared atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "owner-1", Messages: []ticket.Message{{ID: "123", AuthorID: "owner-1", Content: "attached logs"}}})
	}))
	t.Cleanup(srv.Close)
	investigator := preparingInvestigator{fakeInvestigator: &fakeInvestigator{
		triage: func(_ context.Context, inv agent.Investigation) (bool, string, error) {
			if inv.Conversation != "prepared" {
				t.Error("triage did not receive preparation")
			}
			return true, "", nil
		},
		investigate: func(_ context.Context, inv agent.Investigation) (agent.Outcome, error) {
			calls <- inv
			return agent.Outcome{}, context.Canceled
		},
	}, prepare: func(_ context.Context, inv agent.Investigation) agent.Investigation {
		prepared.Add(1)
		if len(inv.Messages) != 1 || inv.Messages[0].Content != "attached logs" {
			t.Error("preparation did not receive fresh messages")
		}
		inv.Conversation = "prepared"
		return inv
	}}
	pool := startTicketPool(t, investigator, bot.NewClient(srv.URL, "secret"), Options{FetchTicketContext: true}, 1)
	pool.Enqueue(ticketInvestigation())
	if got := awaitInvestigation(t, calls); got.Conversation != "prepared" || prepared.Load() != 1 {
		t.Fatalf("context=%+v preparation count=%d", got, prepared.Load())
	}
}

func TestQuietWaitDoesNotSpendInvestigationTimeout(t *testing.T) {
	calls := make(chan agent.Investigation, 1)
	investigator := &fakeInvestigator{triage: func(ctx context.Context, inv agent.Investigation) (bool, string, error) {
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) < 40*time.Millisecond {
			t.Error("quiet wait spent investigation timeout")
		}
		calls <- inv
		return false, "", context.Canceled
	}}
	pool := NewPool(investigator, nil, 50*time.Millisecond, 1, Options{TicketQuietPeriod: 100 * time.Millisecond})
	ctx, cancel := context.WithCancel(context.Background())
	pool.Run(ctx, 1)
	t.Cleanup(func() { cancel(); pool.Wait() })
	pool.Enqueue(ticketInvestigation())
	awaitInvestigation(t, calls)
}

func TestFreshContextRecoversFromTransientCallbackFailures(t *testing.T) {
	calls := make(chan agent.Investigation, 1)
	var attempts atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if attempts.Add(1) < 3 {
			w.WriteHeader(503)
			return
		}
		_ = json.NewEncoder(w).Encode(ticket.Context{TicketThreadID: "ticket-1", DiscordUserID: "owner-1", Messages: []ticket.Message{{ID: "123", AuthorID: "owner-1", Content: "fresh after retry"}}})
	}))
	t.Cleanup(srv.Close)
	pool := startTicketPool(t, &fakeInvestigator{triage: func(_ context.Context, inv agent.Investigation) (bool, string, error) {
		calls <- inv
		return false, "", context.Canceled
	}}, bot.NewClient(srv.URL, "secret"), Options{FetchTicketContext: true}, 1)
	pool.Enqueue(ticketInvestigation())
	if got := awaitInvestigation(t, calls); len(got.Messages) != 1 || got.Messages[0].Content != "fresh after retry" || attempts.Load() != 3 {
		t.Fatalf("context=%+v attempts=%d", got, attempts.Load())
	}
}

func TestOwnerActivityDoesNotCancelOrRestartAnAutomaticInvestigation(t *testing.T) {
	calls := make(chan agent.Investigation, 2)
	cancelled := make(chan struct{}, 1)
	release := make(chan struct{})
	pool := startTicketPool(t, &fakeInvestigator{
		triage: func(context.Context, agent.Investigation) (bool, string, error) { return true, "", nil },
		investigate: func(ctx context.Context, inv agent.Investigation) (agent.Outcome, error) {
			calls <- inv
			select {
			case <-ctx.Done():
				cancelled <- struct{}{}
			case <-release:
			}
			return agent.Outcome{}, context.Canceled
		},
	}, nil, Options{TicketQuietPeriod: 50 * time.Millisecond}, 1)
	inv := ticketInvestigation()
	pool.Enqueue(inv)
	awaitInvestigation(t, calls)
	pool.RecordActivity(inv.TicketThreadID, ticket.Activity{AuthorID: inv.DiscordUserID, MessageID: "456"})
	select {
	case <-cancelled:
		t.Fatal("new owner message cancelled an in-progress investigation")
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	deadline := time.Now().Add(time.Second)
	for {
		pool.mu.Lock()
		pending := len(pool.jobs)
		pool.mu.Unlock()
		if pending == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("investigation did not finish")
		}
		time.Sleep(time.Millisecond)
	}
	pool.RecordActivity(inv.TicketThreadID, ticket.Activity{AuthorID: inv.DiscordUserID, MessageID: "457"})
	if !pool.Enqueue(inv) {
		t.Fatal("completed automatic request was not acknowledged")
	}
	assertNoInvestigation(t, calls, 100*time.Millisecond)
	inv.RequestedBy = "staff"
	if !pool.Enqueue(inv) {
		t.Fatal("manual retry rejected after automatic completion")
	}
	if got := awaitInvestigation(t, calls); got.RequestedBy != "staff" {
		t.Fatalf("unexpected non-manual rerun: %+v", got)
	}
}

func TestCompletedAutomaticHistoryIsBoundedAndManualRequestsStillRun(t *testing.T) {
	pool := NewPool(&fakeInvestigator{}, nil, time.Second, 1)
	pool.mu.Lock()
	for i := range maxCompletedTickets {
		pool.completed[time.Unix(int64(i), 0).String()] = time.Unix(int64(i), 0)
	}
	pool.rememberCompleted("recent-ticket")
	_, oldestRetained := pool.completed[time.Unix(0, 0).String()]
	_, newestRetained := pool.completed["recent-ticket"]
	count := len(pool.completed)
	pool.mu.Unlock()
	if count != maxCompletedTickets || oldestRetained || !newestRetained {
		t.Fatalf("completed history count=%d oldest=%t newest=%t", count, oldestRetained, newestRetained)
	}
	inv := ticketInvestigation()
	inv.TicketThreadID = "recent-ticket"
	if !pool.Enqueue(inv) {
		t.Fatal("duplicate automatic request was not acknowledged")
	}
	pool.mu.Lock()
	pending := len(pool.jobs)
	pool.mu.Unlock()
	if pending != 0 {
		t.Fatal("completed automatic request scheduled another job")
	}
	inv.RequestedBy = "staff"
	if !pool.Enqueue(inv) {
		t.Fatal("manual retry rejected for a completed ticket")
	}
	pool.mu.Lock()
	pending = len(pool.jobs)
	pool.mu.Unlock()
	if pending != 1 {
		t.Fatal("manual retry was not scheduled")
	}
}
