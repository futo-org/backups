package o11y

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/rs/zerolog"
)

const maxVersionResults = 100

type Version struct {
	Component string `json:"component"`
	Version   string `json:"version"`
	Source    string `json:"source"`
	LastSeen  string `json:"lastSeen,omitempty"`
}

type VersionResult struct {
	Versions           []Version `json:"versions"`
	UnavailableSources []string  `json:"unavailableSources"`
}

func (c *Client) Versions(ctx context.Context, lookback time.Duration) VersionResult {
	result := VersionResult{Versions: []Version{}, UnavailableSources: []string{}}
	if c.CustomerID == "" || lookback <= 0 {
		result.UnavailableSources = []string{"logs", "metrics"}
		return result
	}

	type sourceResult struct {
		source   string
		versions []Version
		err      error
	}
	sources := []struct {
		name string
		get  func(context.Context, time.Duration) ([]Version, error)
	}{
		{name: "logs", get: c.logVersions},
		{name: "metrics", get: c.metricVersions},
	}
	results := make(chan sourceResult, len(sources))
	for _, source := range sources {
		go func() {
			versions, err := source.get(ctx, lookback)
			results <- sourceResult{source: source.name, versions: versions, err: err}
		}()
	}
	for range sources {
		source := <-results
		if source.err != nil {
			zerolog.Ctx(ctx).Warn().Err(source.err).Str("source", source.source).Msg("version lookup unavailable")
			result.UnavailableSources = append(result.UnavailableSources, source.source)
			continue
		}
		result.Versions = append(result.Versions, source.versions...)
	}
	sort.Slice(result.Versions, func(i, j int) bool {
		a, b := result.Versions[i], result.Versions[j]
		if a.Component != b.Component {
			return a.Component < b.Component
		}
		if a.Version != b.Version {
			return a.Version < b.Version
		}
		return a.Source < b.Source
	})
	sort.Strings(result.UnavailableSources)
	return result
}

func (c *Client) logVersions(ctx context.Context, lookback time.Duration) ([]Version, error) {
	query := fmt.Sprintf(`_msg:"[telemetry]" data.version:* | stats by (data.version) max(_time) last | limit %d`, maxVersionResults+1)
	end := time.Now()
	body, err := c.QueryLogs(ctx, query, end.Add(-lookback).Format(time.RFC3339), end.Format(time.RFC3339), maxVersionResults+1)
	if err != nil {
		return nil, err
	}

	versions := []Version{}
	rows := 0
	for _, line := range strings.Split(body, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		rows++
		if rows > maxVersionResults {
			return nil, fmt.Errorf("log versions exceeded %d records", maxVersionResults)
		}
		var row map[string]string
		if err := json.Unmarshal([]byte(line), &row); err != nil {
			return nil, err
		}
		version := strings.TrimSpace(row["data.version"])
		if version == "" {
			continue
		}
		lastSeen := ""
		if last, err := time.Parse(time.RFC3339Nano, row["last"]); err == nil {
			lastSeen = last.UTC().Format(time.RFC3339Nano)
		}
		versions = append(versions, Version{
			Component: "orchestration-api (client)",
			Version:   version,
			Source:    "logs",
			LastSeen:  lastSeen,
		})
	}
	return versions, nil
}

func (c *Client) metricVersions(ctx context.Context, lookback time.Duration) ([]Version, error) {
	query := fmt.Sprintf(`max by (customerId, service\.name, service\.version, service_name, service_version) `+
		`(tlast_over_time({service\.version!="" or service_version!=""}[%ds]) keep_metric_names) limit %d`,
		int64(math.Ceil(lookback.Seconds())), maxVersionResults+1)
	params := url.Values{}
	params.Set("query", query)
	params.Set("extra_label", "customerId="+c.CustomerID)
	body, err := c.do(ctx, c.MetricsURL+"/api/v1/query", params)
	if err != nil {
		return nil, err
	}
	var parsed struct {
		Status    string   `json:"status"`
		IsPartial bool     `json:"isPartial"`
		Warnings  []string `json:"warnings"`
		Data      struct {
			ResultType string `json:"resultType"`
			Result     []struct {
				Metric map[string]string `json:"metric"`
				Value  []json.RawMessage `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &parsed); err != nil {
		return nil, err
	}
	if parsed.Status != "success" || parsed.Data.ResultType != "vector" || parsed.IsPartial || len(parsed.Warnings) != 0 {
		return nil, fmt.Errorf("metric versions query did not return a complete vector")
	}
	if len(parsed.Data.Result) > maxVersionResults {
		return nil, fmt.Errorf("metric versions exceeded %d records", maxVersionResults)
	}
	versions := map[string]Version{}
	for _, row := range parsed.Data.Result {
		if row.Metric["customerId"] != c.CustomerID {
			return nil, fmt.Errorf("metric versions returned an unexpected customer")
		}
		component, version := row.Metric["service.name"], row.Metric["service.version"]
		if version == "" {
			component, version = row.Metric["service_name"], row.Metric["service_version"]
		}
		component, version = strings.TrimSpace(component), strings.TrimSpace(version)
		if component == "" || version == "" {
			continue
		}
		if len(row.Value) != 2 {
			return nil, fmt.Errorf("metric versions returned an invalid sample")
		}
		var rawLast string
		if err := json.Unmarshal(row.Value[1], &rawLast); err != nil {
			return nil, err
		}
		seconds, err := strconv.ParseFloat(rawLast, 64)
		if err != nil || math.IsInf(seconds, 0) || math.IsNaN(seconds) || seconds <= 0 {
			return nil, fmt.Errorf("metric versions returned an invalid last-seen time")
		}
		lastSeen := time.UnixMilli(int64(seconds * 1000)).UTC()
		key := component + "\x00" + version
		previous, exists := versions[key]
		if exists {
			previousLastSeen, err := time.Parse(time.RFC3339Nano, previous.LastSeen)
			if err == nil && !previousLastSeen.Before(lastSeen) {
				continue
			}
		}
		versions[key] = Version{Component: component + " (service)", Version: version, Source: "metrics", LastSeen: lastSeen.Format(time.RFC3339Nano)}
	}
	result := make([]Version, 0, len(versions))
	for _, version := range versions {
		result = append(result, version)
	}
	return result, nil
}
