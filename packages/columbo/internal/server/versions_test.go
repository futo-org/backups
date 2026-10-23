package server

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
	"time"

	"columbo/internal/o11y"
)

func TestVersionsEndpointUsesAuthenticatedCustomerWithoutInvestigationWorker(t *testing.T) {
	want := o11y.VersionResult{
		Versions:           []o11y.Version{{Component: "orchestration-api (client)", Version: "0.43.0", Source: "logs", LastSeen: "2026-10-20T09:02:03Z"}},
		UnavailableSources: []string{"metrics"},
	}
	called := false
	handler := New("secret", nil).WithVersionLookup(func(ctx context.Context, userID string) (o11y.VersionResult, error) {
		called = true
		if userID != "user-1" {
			t.Errorf("customer = %q", userID)
		}
		return want, nil
	}).Handler()

	response := request(handler, http.MethodGet, "/internal/users/user-1/versions", "secret", "")

	var got o11y.VersionResult
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusOK || response.Header().Get("Content-Type") != "application/json" || !called || !reflect.DeepEqual(got, want) {
		t.Fatalf("status = %d, called = %t, versions = %+v", response.Code, called, got)
	}
}

func TestVersionsEndpointRequiresInternalSecretBeforeLookup(t *testing.T) {
	for _, tc := range []struct {
		name       string
		configured string
		presented  string
	}{
		{name: "unconfigured", presented: "secret"},
		{name: "missing", configured: "secret"},
		{name: "wrong", configured: "secret", presented: "wrong"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			called := false
			handler := New(tc.configured, nil).WithVersionLookup(func(context.Context, string) (o11y.VersionResult, error) {
				called = true
				return o11y.VersionResult{}, nil
			}).Handler()

			response := request(handler, http.MethodGet, "/internal/users/user-1/versions", tc.presented, "")

			if response.Code != http.StatusUnauthorized || called {
				t.Fatalf("status = %d, called = %t", response.Code, called)
			}
		})
	}
}

func TestVersionsEndpointReturnsEmptyArraysForMissingTelemetry(t *testing.T) {
	handler := New("secret", nil).WithVersionLookup(func(context.Context, string) (o11y.VersionResult, error) {
		return o11y.VersionResult{}, nil
	}).Handler()

	response := request(handler, http.MethodGet, "/internal/users/user-1/versions", "secret", "")

	if response.Code != http.StatusOK || response.Body.String() != "{\"versions\":[],\"unavailableSources\":[]}\n" {
		t.Fatalf("status = %d, body = %q", response.Code, response.Body.String())
	}
}

func TestVersionsEndpointReportsUnavailableLookup(t *testing.T) {
	for _, tc := range []struct {
		name   string
		lookup VersionLookup
	}{
		{name: "not configured"},
		{name: "lookup error", lookup: func(context.Context, string) (o11y.VersionResult, error) {
			return o11y.VersionResult{}, errors.New("backend failed")
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			handler := New("secret", nil).WithVersionLookup(tc.lookup).Handler()

			response := request(handler, http.MethodGet, "/internal/users/user-1/versions", "secret", "")

			if response.Code != http.StatusServiceUnavailable || response.Body.String() != "version lookup unavailable\n" {
				t.Fatalf("status = %d, body = %q", response.Code, response.Body.String())
			}
		})
	}
}

func TestVersionsEndpointRejectsBlankCustomerWithoutLookup(t *testing.T) {
	called := false
	handler := New("secret", nil).WithVersionLookup(func(context.Context, string) (o11y.VersionResult, error) {
		called = true
		return o11y.VersionResult{}, nil
	}).Handler()

	response := request(handler, http.MethodGet, "/internal/users/%20/versions", "secret", "")

	if response.Code != http.StatusBadRequest || called {
		t.Fatalf("status = %d, called = %t", response.Code, called)
	}
}

func TestVersionsEndpointBoundsLookupBeforeDiscordTimeout(t *testing.T) {
	handler := New("secret", nil).WithVersionLookup(func(ctx context.Context, _ string) (o11y.VersionResult, error) {
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) > 3500*time.Millisecond {
			t.Errorf("version lookup deadline = %v, bounded = %t", deadline, ok)
		}
		return o11y.VersionResult{}, nil
	}).Handler()

	response := request(handler, http.MethodGet, "/internal/users/user-1/versions", "secret", "")

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d", response.Code)
	}
}

func TestVersionsEndpointRetainsSuccessfulSourceWhenAnotherTimesOut(t *testing.T) {
	release := make(chan struct{})
	metrics := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}))
	defer metrics.Close()
	defer close(release)
	logs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"data.version":"1.7.0","last":"2026-10-22T12:00:00Z"}` + "\n"))
	}))
	defer logs.Close()
	client := o11y.NewClient(metrics.URL, logs.URL, "user-1")
	handler := New("secret", nil).WithVersionLookup(func(ctx context.Context, _ string) (o11y.VersionResult, error) {
		return client.Versions(ctx, 24*time.Hour), nil
	}).Handler()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	req := httptest.NewRequest(http.MethodGet, "/internal/users/user-1/versions", nil).WithContext(ctx)
	req.Header.Set("X-Internal-Secret", "secret")
	response := httptest.NewRecorder()

	handler.ServeHTTP(response, req)

	var got o11y.VersionResult
	if err := json.Unmarshal(response.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if response.Code != http.StatusOK || len(got.Versions) != 1 || got.Versions[0].Version != "1.7.0" || !reflect.DeepEqual(got.UnavailableSources, []string{"metrics"}) {
		t.Fatalf("status = %d, versions = %+v", response.Code, got)
	}
	if ctx.Err() != nil {
		t.Fatalf("lookup exceeded its deadline: %v", ctx.Err())
	}
}
