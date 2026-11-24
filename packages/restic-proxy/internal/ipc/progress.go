package ipc

import (
	"context"
	"encoding/json"
	"io"
	"time"
)

const ProgressType = "progress"

type Progress struct {
	Type          string `json:"type"`
	UploadedBytes int64  `json:"uploadedBytes"`
}

// A write blocked on a parent that stopped reading holds only this goroutine; the ticker drops the ticks in
// between, so the next line carries the latest total instead of a backlog.
func ReportProgress(ctx context.Context, parent io.Writer, interval time.Duration, uploaded func() int64) error {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	encoder := json.NewEncoder(parent)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			if err := encoder.Encode(Progress{Type: ProgressType, UploadedBytes: uploaded()}); err != nil {
				return err
			}
		}
	}
}
