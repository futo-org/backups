package o11y

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"reflect"
	"strings"
	"testing"
	"time"
)

type versionRequest struct {
	path string
	form url.Values
}

func versionBackend(t *testing.T, logs, metrics string, unavailable string) (*Client, <-chan versionRequest) {
	t.Helper()
	requests := make(chan versionRequest, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := r.ParseForm(); err != nil {
			t.Error(err)
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		requests <- versionRequest{path: r.URL.Path, form: r.Form}
		switch r.URL.Path {
		case "/select/logsql/query":
			if unavailable == "logs" {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			_, _ = w.Write([]byte(logs))
		case "/api/v1/query":
			if unavailable == "metrics" {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			_, _ = w.Write([]byte(metrics))
		default:
			t.Errorf("unexpected path: %s", r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	return NewClient(srv.URL, srv.URL, "user-1"), requests
}

const emptyVersionMetrics = `{"status":"success","data":{"resultType":"vector","result":[]}}`

func TestVersionsFindsClientAndServiceEvidenceWithPerUserQueries(t *testing.T) {
	client, requests := versionBackend(t, strings.Join([]string{
		`{"data.version":"0.43.0","last":"2026-10-20T09:02:03Z"}`,
		`{"data.version":"0.42.0","last":"2026-10-18T08:01:02Z"}`,
		`{"data.version":"","last":"2026-10-21T08:01:02Z"}`,
		"",
	}, "\n"), `{"status":"success","data":{"resultType":"vector","result":[
		{"metric":{"customerId":"user-1","service.name":"michael","service.version":"0.60.0"},"value":[1792486923,"1792486923"]},
		{"metric":{"customerId":"user-1","service_name":"michael","service_version":"0.60.0"},"value":[1792486923,"1792486922"]},
		{"metric":{"customerId":"user-1","service_name":"michael","service_version":"0.60.0"},"value":[1792486923,"1792486923.456"]},
		{"metric":{"customerId":"user-1","service_name":"yucca-api","service_version":"0.61.0"},"value":[1792486923,"1792486923.123"]},
		{"metric":{"customerId":"user-1","service_version":"0.1.0"},"value":[1792486923,"1792486923"]}
	]}}`, "")

	result := client.Versions(context.Background(), 30*24*time.Hour)

	want := VersionResult{
		Versions: []Version{
			{Component: "michael (service)", Version: "0.60.0", Source: "metrics", LastSeen: time.UnixMilli(1792486923456).UTC().Format(time.RFC3339Nano)},
			{Component: "orchestration-api (client)", Version: "0.42.0", Source: "logs", LastSeen: "2026-10-18T08:01:02Z"},
			{Component: "orchestration-api (client)", Version: "0.43.0", Source: "logs", LastSeen: "2026-10-20T09:02:03Z"},
			{Component: "yucca-api (service)", Version: "0.61.0", Source: "metrics", LastSeen: time.UnixMilli(1792486923123).UTC().Format(time.RFC3339Nano)},
		},
		UnavailableSources: []string{},
	}
	if !reflect.DeepEqual(result, want) {
		t.Fatalf("versions = %+v, want %+v", result, want)
	}
	for range 2 {
		request := <-requests
		switch request.path {
		case "/select/logsql/query":
			query := request.form.Get("query")
			if !strings.HasPrefix(query, `(user:="user-1" or customerId:="user-1") and (_msg:"[telemetry]" data.version:*)`) {
				t.Fatalf("logs query is not user-scoped: %s", query)
			}
			if !strings.Contains(query, "stats by (data.version) max(_time) last | limit 101") || request.form.Get("limit") != "101" {
				t.Fatalf("logs query does not bound distinct version results: %s", query)
			}
			start, err := time.Parse(time.RFC3339, request.form.Get("start"))
			if err != nil || time.Since(start) < 30*24*time.Hour-time.Minute {
				t.Fatalf("unexpected lookback start: %s", request.form.Get("start"))
			}
		case "/api/v1/query":
			if request.form.Get("extra_label") != "customerId=user-1" {
				t.Fatalf("metrics query is not user-scoped: %v", request.form)
			}
			query := request.form.Get("query")
			if !strings.Contains(query, `{service\.version!="" or service_version!=""}[2592000s]`) || !strings.HasSuffix(query, "limit 101") {
				t.Fatalf("unexpected version metric selector: %s", query)
			}
		}
	}
}

func TestVersionsDistinguishesNoTelemetryFromSourceFailures(t *testing.T) {
	for _, source := range []string{"", "logs", "metrics"} {
		t.Run(source, func(t *testing.T) {
			client, _ := versionBackend(t, "", emptyVersionMetrics, source)

			result := client.Versions(context.Background(), time.Hour)

			if len(result.Versions) != 0 || result.Versions == nil {
				t.Fatalf("versions = %+v", result.Versions)
			}
			want := []string{}
			if source != "" {
				want = []string{source}
			}
			if !reflect.DeepEqual(result.UnavailableSources, want) {
				t.Fatalf("unavailable = %v, want %v", result.UnavailableSources, want)
			}
		})
	}
}

func TestVersionsPreservesSuccessfulSourceWhenOtherSourceFails(t *testing.T) {
	client, _ := versionBackend(t, `{"data.version":"0.43.0"}`, emptyVersionMetrics, "metrics")

	result := client.Versions(context.Background(), time.Hour)

	if len(result.Versions) != 1 || result.Versions[0].Version != "0.43.0" || !reflect.DeepEqual(result.UnavailableSources, []string{"metrics"}) {
		t.Fatalf("versions = %+v", result)
	}
}

func TestVersionsRejectsIncompleteAndInvalidEvidence(t *testing.T) {
	logsOverflow := strings.Repeat(`{"data.version":"0.43.0"}`+"\n", maxVersionResults+1)
	metricRows := make([]any, maxVersionResults+1)
	for i := range metricRows {
		metricRows[i] = map[string]any{"metric": map[string]string{"customerId": "user-1", "service.name": "michael", "service.version": "v1"}, "value": []any{1, "1"}}
	}
	metricsOverflow, err := json.Marshal(map[string]any{"status": "success", "data": map[string]any{"resultType": "vector", "result": metricRows}})
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name    string
		logs    string
		metrics string
		source  string
	}{
		{name: "malformed logs", logs: "{", metrics: emptyVersionMetrics, source: "logs"},
		{name: "too many log versions", logs: logsOverflow, metrics: emptyVersionMetrics, source: "logs"},
		{name: "malformed metrics", metrics: "{", source: "metrics"},
		{name: "error metrics", metrics: `{"status":"error"}`, source: "metrics"},
		{name: "partial metrics", metrics: `{"status":"success","isPartial":true,"data":{"resultType":"vector","result":[]}}`, source: "metrics"},
		{name: "metrics warnings", metrics: `{"status":"success","warnings":["truncated"],"data":{"resultType":"vector","result":[]}}`, source: "metrics"},
		{name: "too many metric versions", metrics: string(metricsOverflow), source: "metrics"},
		{name: "different customer", metrics: `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"customerId":"other","service.name":"michael","service.version":"v1"},"value":[1,"1"]}]}}`, source: "metrics"},
		{name: "malformed metric sample", metrics: `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"customerId":"user-1","service.name":"michael","service.version":"v1"},"value":[]}]}}`, source: "metrics"},
		{name: "numeric metric sample", metrics: `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"customerId":"user-1","service.name":"michael","service.version":"v1"},"value":[1,1]}]}}`, source: "metrics"},
		{name: "invalid metric timestamp", metrics: `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"customerId":"user-1","service.name":"michael","service.version":"v1"},"value":[1,"NaN"]}]}}`, source: "metrics"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client, _ := versionBackend(t, tc.logs, tc.metrics, "")

			result := client.Versions(context.Background(), time.Hour)

			if len(result.Versions) != 0 || !reflect.DeepEqual(result.UnavailableSources, []string{tc.source}) {
				t.Fatalf("versions = %+v", result)
			}
		})
	}
}

func TestVersionsRefusesMissingScopeAndInvalidLookbackWithoutQuerying(t *testing.T) {
	for _, tc := range []struct {
		name     string
		customer string
		lookback time.Duration
	}{
		{name: "missing customer", lookback: time.Hour},
		{name: "invalid lookback", customer: "user-1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client := NewClient("http://127.0.0.1:1", "http://127.0.0.1:1", tc.customer)

			result := client.Versions(context.Background(), tc.lookback)

			if len(result.Versions) != 0 || !reflect.DeepEqual(result.UnavailableSources, []string{"logs", "metrics"}) {
				t.Fatalf("versions = %+v", result)
			}
		})
	}
}
