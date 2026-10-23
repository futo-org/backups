package server

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"columbo/internal/agent"
	"columbo/internal/ticket"
	"columbo/internal/worker"
)

const validBody = `{"ticketThreadId":"t1","staffThreadId":"s1","discordUserId":"d1","username":"u","userId":"user-1","description":"my backups fail"}`

type fakeInvestigations struct {
	enqueue    func(agent.Investigation) bool
	startAdhoc func(userID, prompt string) (string, error)
	getAdhoc   func(id string) (worker.AdhocJob, bool)
	activity   func(string, ticket.Activity)
}

func (f *fakeInvestigations) Enqueue(inv agent.Investigation) bool {
	return f.enqueue(inv)
}

func (f *fakeInvestigations) StartAdhoc(userID, prompt string) (string, error) {
	return f.startAdhoc(userID, prompt)
}

func (f *fakeInvestigations) GetAdhoc(id string) (worker.AdhocJob, bool) {
	return f.getAdhoc(id)
}

func accepting() *fakeInvestigations {
	return &fakeInvestigations{
		enqueue:    func(agent.Investigation) bool { return true },
		startAdhoc: func(string, string) (string, error) { return "job-1", nil },
		getAdhoc:   func(string) (worker.AdhocJob, bool) { return worker.AdhocJob{ID: "job-1", Status: "running"}, true },
	}
}

func request(handler http.Handler, method, path, secret, body string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if secret != "" {
		req.Header.Set("X-Internal-Secret", secret)
	}
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, req)
	return recorder
}

func post(handler http.Handler, secret, body string) *httptest.ResponseRecorder {
	return request(handler, http.MethodPost, "/internal/investigations", secret, body)
}

func TestGuardFailsClosedWithoutConfiguredSecret(t *testing.T) {
	handler := New("", accepting()).Handler()
	if got := post(handler, "", validBody).Code; got != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", got)
	}
}

func TestGuardRejectsWrongSecret(t *testing.T) {
	handler := New("right", accepting()).Handler()
	if got := post(handler, "wrong", validBody).Code; got != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", got)
	}
}

func TestValidRequestIsAccepted(t *testing.T) {
	var enqueued agent.Investigation
	api := accepting()
	api.enqueue = func(inv agent.Investigation) bool {
		enqueued = inv
		return true
	}
	handler := New("secret", api).Handler()
	if got := post(handler, "secret", validBody).Code; got != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", got)
	}
	if enqueued.UserID != "user-1" || enqueued.StaffThreadID != "s1" {
		t.Fatalf("unexpected investigation %+v", enqueued)
	}
}

func TestMissingFieldsAreRejected(t *testing.T) {
	handler := New("secret", accepting()).Handler()
	if got := post(handler, "secret", `{"staffThreadId":"s1"}`).Code; got != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", got)
	}
}

func TestFullQueueReturns503(t *testing.T) {
	api := accepting()
	api.enqueue = func(agent.Investigation) bool { return false }
	handler := New("secret", api).Handler()
	if got := post(handler, "secret", validBody).Code; got != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503", got)
	}
}

func TestAdhocStartReturnsJobID(t *testing.T) {
	api := accepting()
	handler := New("secret", api).Handler()
	rec := request(handler, http.MethodPost, "/internal/investigations/adhoc", "secret", `{"userId":"user-1","prompt":"why slow"}`)
	if rec.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", rec.Code)
	}
	if !strings.Contains(rec.Body.String(), `"id":"job-1"`) {
		t.Fatalf("body = %q", rec.Body.String())
	}
}

func TestAdhocStartValidatesAndSurfacesErrors(t *testing.T) {
	api := accepting()
	handler := New("secret", api).Handler()
	if got := request(handler, http.MethodPost, "/internal/investigations/adhoc", "secret", `{"userId":"user-1"}`).Code; got != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", got)
	}

	api.startAdhoc = func(string, string) (string, error) { return "", errors.New("columbo is disabled") }
	rec := request(handler, http.MethodPost, "/internal/investigations/adhoc", "secret", `{"userId":"user-1","prompt":"p"}`)
	if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "disabled") {
		t.Fatalf("status = %d body = %q", rec.Code, rec.Body.String())
	}
}

func TestAdhocGetReturnsJobOr404(t *testing.T) {
	api := accepting()
	api.getAdhoc = func(id string) (worker.AdhocJob, bool) {
		if id == "job-1" {
			return worker.AdhocJob{ID: "job-1", Status: "done", Note: "all good"}, true
		}
		return worker.AdhocJob{}, false
	}
	handler := New("secret", api).Handler()

	rec := request(handler, http.MethodGet, "/internal/investigations/adhoc/job-1", "secret", "")
	if rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), `"status":"done"`) {
		t.Fatalf("status = %d body = %q", rec.Code, rec.Body.String())
	}
	if got := request(handler, http.MethodGet, "/internal/investigations/adhoc/nope", "secret", "").Code; got != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", got)
	}
}

func (f *fakeInvestigations) RecordActivity(threadID string, activity ticket.Activity) {
	if f.activity != nil {
		f.activity(threadID, activity)
	}
}

func TestTicketActivityRequiresInternalSecretAndValidMessage(t *testing.T) {
	api := accepting()
	var gotThread string
	var gotActivity ticket.Activity
	api.activity = func(threadID string, activity ticket.Activity) { gotThread = threadID; gotActivity = activity }
	handler := New("secret", api).Handler()
	path := "/internal/investigations/tickets/ticket-1/activity"
	for _, test := range []struct {
		name, secret, body string
		status             int
	}{
		{"unauthorized", "wrong", `{"authorId":"owner","messageId":"123"}`, 401},
		{"missing author", "secret", `{"messageId":"123"}`, 400},
		{"missing message", "secret", `{"authorId":"owner"}`, 400},
		{"invalid message", "secret", `{"authorId":"owner","messageId":"bad"}`, 400},
		{"zero message", "secret", `{"authorId":"owner","messageId":"0"}`, 400},
		{"invalid JSON", "secret", `{`, 400},
	} {
		t.Run(test.name, func(t *testing.T) {
			if got := request(handler, http.MethodPost, path, test.secret, test.body).Code; got != test.status {
				t.Fatalf("status=%d want%d", got, test.status)
			}
		})
	}
	if gotThread != "" {
		t.Fatal("invalid activity reached pool")
	}
	if got := request(handler, http.MethodPost, path, "secret", `{"authorId":"owner","messageId":"123"}`).Code; got != 204 {
		t.Fatalf("status=%d", got)
	}
	if gotThread != "ticket-1" || gotActivity.AuthorID != "owner" || gotActivity.MessageID != "123" {
		t.Fatalf("activity=%s %+v", gotThread, gotActivity)
	}
	if got := request(New("", api).Handler(), http.MethodPost, path, "", `{"authorId":"owner","messageId":"123"}`).Code; got != 401 {
		t.Fatalf("unconfigured secret status=%d", got)
	}
}
