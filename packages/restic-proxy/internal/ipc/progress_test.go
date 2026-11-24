package ipc

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestReportProgress_WritesTheCurrentTotalEveryInterval(t *testing.T) {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	defer read.Close()
	defer write.Close()

	var uploaded atomic.Int64
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	go func() { _ = ReportProgress(ctx, write, 5*time.Millisecond, uploaded.Load) }()

	lines := bufio.NewScanner(read)
	var last Progress
	for _, total := range []int64{0, 4096, 1 << 30} {
		uploaded.Store(total)
		deadline := time.Now().Add(2 * time.Second)
		for last.UploadedBytes != total {
			if time.Now().After(deadline) {
				t.Fatalf("never reported %d uploaded bytes, last saw %d", total, last.UploadedBytes)
			}
			if !lines.Scan() {
				t.Fatalf("scan: %v", lines.Err())
			}
			if err := json.Unmarshal(lines.Bytes(), &last); err != nil {
				t.Fatalf("decode %q: %v", lines.Text(), err)
			}
			if last.Type != ProgressType {
				t.Fatalf("expected a %q message, got %q", ProgressType, last.Type)
			}
		}
	}
}

type stalledParent struct {
	mu       sync.Mutex
	release  chan struct{}
	attempts atomic.Int64
	lines    []Progress
}

func (parent *stalledParent) Write(payload []byte) (int, error) {
	parent.attempts.Add(1)
	<-parent.release

	var progress Progress
	if err := json.Unmarshal(payload, &progress); err != nil {
		return 0, err
	}

	parent.mu.Lock()
	defer parent.mu.Unlock()
	parent.lines = append(parent.lines, progress)
	return len(payload), nil
}

func (parent *stalledParent) written() []Progress {
	parent.mu.Lock()
	defer parent.mu.Unlock()
	return append([]Progress(nil), parent.lines...)
}

func TestReportProgress_CoalescesWhileTheParentStopsReading(t *testing.T) {
	parent := &stalledParent{release: make(chan struct{})}
	var uploaded atomic.Int64

	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	go func() { _ = ReportProgress(ctx, parent, time.Millisecond, uploaded.Load) }()

	deadline := time.Now().Add(2 * time.Second)
	for parent.attempts.Load() == 0 {
		if time.Now().After(deadline) {
			t.Fatal("never tried to write")
		}
		time.Sleep(time.Millisecond)
	}

	started := time.Now()
	for range 100_000 {
		uploaded.Add(1)
	}
	if elapsed := time.Since(started); elapsed > 500*time.Millisecond {
		t.Errorf("counting stalled behind the blocked parent for %s", elapsed)
	}
	time.Sleep(50 * time.Millisecond)
	if attempts := parent.attempts.Load(); attempts != 1 {
		t.Errorf("expected one blocked write while stalled, got %d", attempts)
	}

	close(parent.release)
	for {
		written := parent.written()
		if len(written) > 0 && written[len(written)-1].UploadedBytes == 100_000 {
			if len(written) > 3 {
				t.Errorf("expected the stalled ticks to be coalesced, got %d writes", len(written))
			}
			break
		}
		if time.Now().After(deadline.Add(2 * time.Second)) {
			t.Fatalf("never reported the latest total after the parent resumed, wrote %v", written)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestReportProgress_StopsWhenTheParentGoesAway(t *testing.T) {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	defer write.Close()
	read.Close()

	done := make(chan error, 1)
	go func() { done <- ReportProgress(t.Context(), write, time.Millisecond, func() int64 { return 1 }) }()

	select {
	case err := <-done:
		if err == nil {
			t.Error("expected the write error to be returned")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("kept reporting after the parent closed its end")
	}
}

func TestReportProgress_StopsWhenCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		done <- ReportProgress(ctx, &stalledParent{release: make(chan struct{})}, time.Hour, func() int64 { return 0 })
	}()

	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("expected context.Canceled, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("did not stop after cancellation")
	}
}
