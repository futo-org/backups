package bot

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestGetTicketContextAuthenticatesAndDecodes(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.EscapedPath() != "/internal/tickets/thread%2F1/context" || r.Header.Get("X-Internal-Secret") != "secret" || r.Method != http.MethodGet {
			t.Errorf("unexpected callback: %s %s", r.Method, r.URL.EscapedPath())
		}
		_, _ = w.Write([]byte(`{"ticketThreadId":"thread/1","discordUserId":"owner","closed":false,"messages":[{"id":"123","authorId":"owner","content":"followup"}]}`))
	}))
	defer srv.Close()
	fresh, err := NewClient(srv.URL, "secret").GetTicketContext(context.Background(), "thread/1")
	if err != nil || fresh.TicketThreadID != "thread/1" || len(fresh.Messages) != 1 || fresh.Messages[0].Content != "followup" {
		t.Fatalf("context=%+v err=%v", fresh, err)
	}
}

func TestGetTicketContextUsesBoundedDeadline(t *testing.T) {
	client := NewClient("http://bot", "secret")
	client.HTTPClient = &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		deadline, ok := r.Context().Deadline()
		if !ok || time.Until(deadline) > ticketContextTimeout || time.Until(deadline) < 9*time.Second {
			t.Errorf("callback deadline=%s present=%v", deadline, ok)
		}
		return nil, context.DeadlineExceeded
	})}
	_, err := client.GetTicketContext(context.Background(), "thread")
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err=%v", err)
	}
}

func TestGetTicketContextRejectsInvalidResponses(t *testing.T) {
	for _, test := range []struct {
		name   string
		status int
		body   string
	}{{"missing", 404, `{}`}, {"invalid json", 200, `{`}, {"oversized", 200, strings.Repeat(" ", maxTicketContextBytes+1)}} {
		t.Run(test.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(test.status)
				_, _ = w.Write([]byte(test.body))
			}))
			defer srv.Close()
			if _, err := NewClient(srv.URL, "secret").GetTicketContext(context.Background(), "thread"); err == nil {
				t.Fatal("invalid response accepted")
			}
		})
	}
}
