package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"columbo/internal/agent"
	"columbo/internal/server"
)

func TestDisabledPoolAcceptsAutomaticInvestigationsAndRejectsStaffRequests(t *testing.T) {
	for _, tc := range []struct {
		name        string
		requestedBy string
		accepted    bool
	}{
		{name: "automatic investigation", accepted: true},
		{name: "staff investigation", requestedBy: "staff-1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pool := &gatedPool{enabled: false}

			accepted := pool.Enqueue(agent.Investigation{RequestedBy: tc.requestedBy})

			if accepted != tc.accepted {
				t.Fatalf("accepted = %t, want %t", accepted, tc.accepted)
			}
		})
	}
}

func TestDisabledPoolReportsUnavailableForExplicitInvestigationRequests(t *testing.T) {
	handler := server.New("secret", &gatedPool{enabled: false}).Handler()
	for _, tc := range []struct {
		name        string
		requestedBy string
		status      int
	}{
		{name: "automatic investigation", status: http.StatusAccepted},
		{name: "staff investigation", requestedBy: "staff-1", status: http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body, err := json.Marshal(agent.Investigation{
				StaffThreadID: "staff-thread-1", UserID: "user-1", Description: "Backup failed", RequestedBy: tc.requestedBy,
			})
			if err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodPost, "/internal/investigations", bytes.NewReader(body))
			request.Header.Set("X-Internal-Secret", "secret")
			response := httptest.NewRecorder()

			handler.ServeHTTP(response, request)

			if response.Code != tc.status {
				t.Fatalf("status = %d, want %d", response.Code, tc.status)
			}
		})
	}
}
