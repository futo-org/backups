package handlers

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"time"

	"support-logs-streamer/internal/auth"
	"support-logs-streamer/internal/httputil"
	"support-logs-streamer/internal/stats"

	"github.com/rs/zerolog/hlog"
	"go.opentelemetry.io/otel/attribute"
	otellog "go.opentelemetry.io/otel/log"
)

const (
	maxCompressedBytes   = 16 << 20
	maxDecompressedBytes = 128 << 20
	maxMessageBytes      = 64 << 10
	// Large batches are exported in slices so a single OTLP request stays well
	// under VictoriaLogs' insert request size limit.
	exportChunkBytes = 4 << 20
)

type clientLine struct {
	Time    string `json:"time"`
	Stream  string `json:"stream"`
	Command string `json:"command"`
	Message string `json:"message"`
}

var severities = map[string]otellog.Severity{
	"stdout": otellog.SeverityInfo,
	"meta":   otellog.SeverityInfo,
	"stderr": otellog.SeverityWarn,
}

type batchHeaders struct {
	seq     int64
	dropped int64
	final   bool
}

func parseBatchHeaders(r *http.Request) (batchHeaders, string) {
	if !strings.EqualFold(strings.TrimSpace(r.Header.Get("Content-Encoding")), "gzip") {
		return batchHeaders{}, "Content-Encoding must be gzip"
	}
	if mediaType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type")); err != nil || mediaType != "application/x-ndjson" {
		return batchHeaders{}, "Content-Type must be application/x-ndjson"
	}

	seq, err := strconv.ParseInt(r.Header.Get("X-Batch-Seq"), 10, 64)
	if err != nil || seq < 0 {
		return batchHeaders{}, "X-Batch-Seq must be an integer >= 0"
	}

	var dropped int64
	if v := r.Header.Get("X-Dropped-Lines"); v != "" {
		dropped, err = strconv.ParseInt(v, 10, 64)
		if err != nil || dropped < 0 {
			return batchHeaders{}, "X-Dropped-Lines must be an integer >= 0"
		}
	}

	return batchHeaders{seq: seq, dropped: dropped, final: r.Header.Get("X-Batch-Final") == "true"}, ""
}

type countingReader struct {
	r io.Reader
	n int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n += int64(n)
	return n, err
}

var errTooLarge = errors.New("batch too large")

func readError(err error) (int, string) {
	var maxBytes *http.MaxBytesError
	if errors.As(err, &maxBytes) || errors.Is(err, errTooLarge) {
		return http.StatusRequestEntityTooLarge, "Batch too large"
	}
	return http.StatusBadRequest, "Body is not valid gzip"
}

func (s *Server) postBatch(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	session := auth.FromContext(ctx)

	headers, problem := parseBatchHeaders(r)
	if problem != "" {
		httputil.WriteError(w, r, http.StatusBadRequest, problem)
		return
	}

	gz, err := gzip.NewReader(http.MaxBytesReader(w, r.Body, maxCompressedBytes))
	if err != nil {
		code, message := readError(err)
		httputil.WriteError(w, r, code, message)
		return
	}
	defer func() { _ = gz.Close() }()

	decompressed := &countingReader{r: io.LimitReader(gz, maxDecompressedBytes+1)}
	reader := bufio.NewReaderSize(decompressed, 64<<10)

	common := []attribute.KeyValue{
		attribute.String("user", session.User),
		attribute.String("customerId", session.User),
		attribute.String("support_session", session.Session),
		attribute.String("job", session.Job),
		attribute.Int64("batch_seq", headers.seq),
	}
	if session.Connection != "" {
		common = append(common, attribute.String("connection", session.Connection))
	}
	if session.JobName != "" {
		common = append(common, attribute.String("job_name", session.JobName))
	}

	batch := s.Sink.NewBatch()
	var lines, malformed int64
	chunkBytes := 0
	now := time.Now()

	export := func() bool {
		if err := batch.Export(ctx); err != nil {
			hlog.FromRequest(r).Error().Err(err).Msg("failed to export support log batch")
			if s.Metrics != nil {
				s.Metrics.ExportFailures.Add(ctx, 1)
			}
			httputil.WriteError(w, r, http.StatusServiceUnavailable, "Log sink unavailable, retry later")
			return false
		}
		chunkBytes = 0
		return true
	}

	for {
		raw, readErr := reader.ReadBytes('\n')
		if decompressed.n > maxDecompressedBytes {
			readErr = errTooLarge
		}
		if readErr != nil && readErr != io.EOF {
			code, message := readError(readErr)
			httputil.WriteError(w, r, code, message)
			return
		}

		if raw = bytes.TrimSpace(raw); len(raw) > 0 {
			record, ok := toRecord(raw, now, common)
			if ok {
				batch.Emit(ctx, record)
				lines++
				chunkBytes += len(raw)
			} else {
				malformed++
			}
		}

		if readErr == io.EOF {
			break
		}
		if chunkBytes >= exportChunkBytes && !export() {
			return
		}
	}

	if !export() {
		return
	}

	s.Stats.Record(session.Session, stats.Delta{
		Lines:        lines,
		Bytes:        decompressed.n,
		Batches:      1,
		DroppedLines: headers.dropped + malformed,
		LastBatchAt:  now,
		Finished:     headers.final,
	})
	if headers.final {
		s.Stats.FlushSessionAsync(context.WithoutCancel(ctx), session.Session)
	}

	if s.Metrics != nil {
		s.Metrics.Batches.Add(ctx, 1)
		s.Metrics.Lines.Add(ctx, lines)
		s.Metrics.Bytes.Add(ctx, decompressed.n)
		s.Metrics.MalformedLines.Add(ctx, malformed)
	}

	w.WriteHeader(http.StatusNoContent)
}

func toRecord(raw []byte, now time.Time, common []attribute.KeyValue) (otellog.Record, bool) {
	var line clientLine
	if err := json.Unmarshal(raw, &line); err != nil {
		return otellog.Record{}, false
	}
	severity, ok := severities[line.Stream]
	if !ok {
		return otellog.Record{}, false
	}

	timestamp, err := time.Parse(time.RFC3339Nano, line.Time)
	if err != nil {
		timestamp = now
	}

	message := line.Message
	if len(message) > maxMessageBytes {
		message = strings.ToValidUTF8(message[:maxMessageBytes], "")
	}

	var record otellog.Record
	record.SetTimestamp(timestamp)
	record.SetObservedTimestamp(now)
	record.SetSeverity(severity)
	record.SetSeverityText(severity.String())
	record.SetBody(attribute.StringValue(message))
	record.AddAttributes(common...)
	record.AddAttributes(attribute.String("command", line.Command), attribute.String("stream", line.Stream))
	return record, true
}
