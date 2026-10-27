package config

import (
	"testing"
	"time"
)

func TestParsePositiveDurationMS(t *testing.T) {
	if d, err := parsePositiveDurationMS("", 15*time.Second); err != nil || d != 15*time.Second {
		t.Errorf("unset: got %v, %v", d, err)
	}
	if d, err := parsePositiveDurationMS("250", time.Second); err != nil || d != 250*time.Millisecond {
		t.Errorf("250: got %v, %v", d, err)
	}
	for _, v := range []string{"0", "-5", "soon"} {
		if _, err := parsePositiveDurationMS(v, time.Second); err == nil {
			t.Errorf("%q was accepted", v)
		}
	}
}

func TestDefaultMetricsIntervalStaysUnderTheCollectorIdleTimeout(t *testing.T) {
	if defaultOTLPMetricsInterval >= time.Minute {
		t.Fatalf("default metrics interval %s reaches vmagent's 1m idle timeout", defaultOTLPMetricsInterval)
	}
}
