package config

import (
	"testing"
	"time"
)

func TestTicketQuietPeriodDefaultsAndCanBeDisabled(t *testing.T) {
	t.Setenv("COLUMBO_PORT", "3000")
	t.Setenv("COLUMBO_TICKET_QUIET_SECONDS", "")
	if got := LoadConfig().TicketQuietPeriod; got != time.Minute {
		t.Fatalf("default quiet=%s", got)
	}
	t.Setenv("COLUMBO_TICKET_QUIET_SECONDS", "0")
	if got := LoadConfig().TicketQuietPeriod; got != 0 {
		t.Fatalf("disabled quiet=%s", got)
	}
	t.Setenv("COLUMBO_TICKET_QUIET_SECONDS", "120")
	if got := LoadConfig().TicketQuietPeriod; got != 2*time.Minute {
		t.Fatalf("configured quiet=%s", got)
	}
}
