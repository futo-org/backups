package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"columbo/internal/ticket"
)

const (
	artifactSecret            = "artifact-local-secret"
	artifactAPIKey            = "artifact-local-model-key"
	artifactThread            = "12345678901234567"
	artifactStaffThread       = "12345678901234568"
	artifactOwner             = "12345678901234569"
	artifactUser              = "11111111-1111-4111-8111-111111111111"
	artifactFollowup          = "The backup now reports a connection timeout after uploading snapshots."
	artifactAttachmentMarker  = "readonly_e2e_file_context"
	artifactFinalNote         = "Artifact verified the follow-up, attached script as data, and exact embedded source revisions."
	artifactHTTPTimeout       = 3 * time.Second
	artifactStartupTimeout    = 30 * time.Second
	artifactFinishTimeout     = 45 * time.Second
	artifactObservationMargin = 250 * time.Millisecond
)

func TestBuiltArtifact(t *testing.T) {
	image, binary := os.Getenv("COLUMBO_E2E_IMAGE"), os.Getenv("COLUMBO_E2E_BINARY")
	if image == "" && binary == "" {
		t.Skip("set COLUMBO_E2E_IMAGE or COLUMBO_E2E_BINARY to test a built artifact")
	}
	if image != "" && binary != "" {
		t.Fatal("choose one artifact: image or binary")
	}
	quiet := time.Minute
	if value := os.Getenv("COLUMBO_E2E_QUIET_SECONDS"); value != "" {
		seconds, err := strconv.Atoi(value)
		if err != nil || seconds < 1 {
			t.Fatal("COLUMBO_E2E_QUIET_SECONDS must be a positive integer")
		}
		quiet = time.Duration(seconds) * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), artifactStartupTimeout+2*quiet+artifactFinishTimeout+10*time.Second+artifactObservationMargin)
	t.Cleanup(cancel)
	failures := make(chan error, 16)
	fail := func(err error) {
		select {
		case failures <- err:
		default:
		}
	}
	var downloads, unsafeDownloads atomic.Int32
	executionMarker := "/tmp/columbo-artifact-" + strconv.FormatInt(time.Now().UnixNano(), 10) + "-executed"
	t.Cleanup(func() {
		if binary != "" {
			_ = os.Remove(executionMarker)
		}
	})
	script := "#!/bin/sh\ntouch " + executionMarker + "\n" + artifactAttachmentMarker + "\n"
	cdn, caPath := newArtifactCDN(t, func(w http.ResponseWriter, r *http.Request) {
		downloads.Add(1)
		if r.URL.Path != "/attachments/12345678901234567/12345678901234572/diagnostic.sh" || r.Header.Get("Authorization") != "" {
			fail(fmt.Errorf("unexpected CDN request: %s", r.URL.Path))
			http.Error(w, "unexpected attachment", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/x-sh")
		_, _ = io.WriteString(w, script)
	})
	proxy := newArtifactProxy(t, cdn.Listener.Addr().String(), fail)
	var contextMu sync.Mutex
	opening := time.Now().UTC()
	conversation := ticket.Context{TicketThreadID: artifactThread, DiscordUserID: artifactOwner, Messages: []ticket.Message{{ID: "12345678901234570", AuthorID: artifactOwner, Username: "Customer", Content: "My backup failed", CreatedAt: opening.Format(time.RFC3339Nano), Attachments: []ticket.Attachment{}}}}
	notes := make(chan string, 4)
	bot := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/unsafe.sh" {
			unsafeDownloads.Add(1)
			_, _ = io.WriteString(w, script)
			return
		}
		if r.Header.Get("X-Internal-Secret") != artifactSecret {
			fail(errors.New("bot callback lacks internal authentication"))
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/internal/tickets/"+artifactThread+"/context":
			contextMu.Lock()
			defer contextMu.Unlock()
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(conversation)
		case r.Method == http.MethodPost && r.URL.Path == "/internal/staff-notes":
			var note struct {
				StaffThreadID string `json:"staffThreadId"`
				Content       string `json:"content"`
			}
			if err := json.NewDecoder(r.Body).Decode(&note); err != nil {
				fail(err)
				http.Error(w, "invalid note", http.StatusBadRequest)
				return
			}
			if note.StaffThreadID != artifactStaffThread {
				fail(fmt.Errorf("note targeted wrong thread %q", note.StaffThreadID))
			}
			select {
			case notes <- note.Content:
			default:
				fail(errors.New("too many staff notes"))
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			fail(fmt.Errorf("unexpected bot callback %s %s", r.Method, r.URL.Path))
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(bot.Close)
	modelState := &artifactModel{fail: fail, firstCall: make(chan time.Time, 1), quiet: quiet, commit: os.Getenv("COLUMBO_E2E_COMMIT")}
	model := httptest.NewServer(http.HandlerFunc(modelState.handle))
	t.Cleanup(model.Close)
	telemetry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "" {
			fail(errors.New("model credentials leaked to telemetry"))
		}
		if err := r.ParseForm(); err != nil {
			fail(err)
			http.Error(w, "invalid form", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/label/__name__/values":
			if r.Form.Get("extra_label") != "customerId="+artifactUser {
				fail(fmt.Errorf("unscoped metrics catalog: %v", r.Form))
			}
			_, _ = io.WriteString(w, `{"status":"success","data":[]}`)
		case "/api/v1/query":
			if r.Form.Get("extra_label") != "customerId="+artifactUser {
				fail(fmt.Errorf("unscoped metrics query: %v", r.Form))
			}
			_, _ = io.WriteString(w, `{"status":"success","data":{"resultType":"vector","result":[{"metric":{"customerId":"`+artifactUser+`","service.name":"michael","service.version":"1.7.0"},"value":[1792490400,"1792490400"]}]}}`)
		case "/select/logsql/query":
			if !strings.HasPrefix(r.Form.Get("query"), `(user:="`+artifactUser+`" or customerId:="`+artifactUser+`") and (`) {
				fail(fmt.Errorf("unscoped logs query: %v", r.Form))
			}
			if strings.Contains(r.Form.Get("query"), "stats by (data.version)") {
				_, _ = io.WriteString(w, `{"data.version":"1.0.0","last":"2026-10-22T12:00:00Z"}`)
			}
		default:
			fail(fmt.Errorf("unexpected telemetry route %s", r.URL.Path))
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(telemetry.Close)
	port := artifactPort(t)
	variables := []string{
		"COLUMBO_PORT=" + strconv.Itoa(port), "INTERNAL_SECRET=" + artifactSecret, "OPENROUTER_API_KEY=" + artifactAPIKey,
		"OPENROUTER_URL=" + model.URL + "/v1", "COLUMBO_MODEL=artifact-investigator", "COLUMBO_TRIAGE_MODEL=artifact-triage",
		"FUTO_BACKUPS_BOT_URL=" + bot.URL, "O11Y_METRICS_URL=" + telemetry.URL, "O11Y_LOGS_URL=" + telemetry.URL,
		"COLUMBO_WORKERS=1", "COLUMBO_MAX_TOOL_CALLS=12", "COLUMBO_TOOL_RESULT_BYTES=1048576",
		"COLUMBO_TIMEOUT_SECONDS=120", "COLUMBO_MODEL_TIMEOUT_SECONDS=10", "COLUMBO_MODEL_ATTEMPTS=1",
		"OTLP_METRICS_ENDPOINT=", "LOG_LEVEL=info", "LOG_FORMAT=json",
		"HTTPS_PROXY=" + proxy.URL, "HTTP_PROXY=", "ALL_PROXY=", "NO_PROXY=127.0.0.1,localhost",
	}
	if os.Getenv("COLUMBO_E2E_QUIET_SECONDS") != "" {
		variables = append(variables, "COLUMBO_TICKET_QUIET_SECONDS="+strconv.Itoa(int(quiet/time.Second)))
	}
	artifact := startArtifact(t, ctx, image, binary, caPath, variables)
	address := "http://127.0.0.1:" + strconv.Itoa(port)
	client := &http.Client{Timeout: artifactHTTPTimeout}
	waitArtifactReady(t, ctx, client, address, artifact, failures)
	postArtifact(t, ctx, client, address+"/internal/investigations", map[string]string{"ticketThreadId": artifactThread, "staffThreadId": artifactStaffThread, "discordUserId": artifactOwner, "username": "Customer", "userId": artifactUser, "description": "My backup failed"}, http.StatusAccepted)
	followupDelay := min(10*time.Second, quiet/3)
	select {
	case at := <-modelState.firstCall:
		t.Fatalf("model called before the follow-up at %s", at)
	case err := <-failures:
		t.Fatal(err)
	case <-artifact.done:
		t.Fatalf("artifact exited early: %v\n%s", artifact.err, artifact.logs.String())
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	case <-time.After(followupDelay):
	}
	followupAt := time.Now().UTC()
	contextMu.Lock()
	conversation.Messages = append(conversation.Messages, ticket.Message{ID: "12345678901234571", AuthorID: artifactOwner, Username: "Customer", Content: artifactFollowup, CreatedAt: followupAt.Format(time.RFC3339Nano), Attachments: []ticket.Attachment{
		{ID: "12345678901234572", Name: "diagnostic.sh", URL: "https://cdn.discordapp.com/attachments/12345678901234567/12345678901234572/diagnostic.sh", ContentType: "application/x-sh", Size: int64(len(script))},
		{ID: "12345678901234573", Name: "blocked.sh", URL: bot.URL + "/unsafe.sh", ContentType: "application/x-sh", Size: int64(len(script))},
	}})
	contextMu.Unlock()
	modelState.mu.Lock()
	modelState.followupAt = followupAt
	modelState.mu.Unlock()
	postArtifact(t, ctx, client, address+"/internal/investigations/tickets/"+artifactThread+"/activity", ticket.Activity{AuthorID: artifactOwner, MessageID: "12345678901234571"}, http.StatusNoContent)
	select {
	case at := <-modelState.firstCall:
		if elapsed := at.Sub(followupAt); elapsed < quiet {
			t.Fatalf("model called after %s, expected at least %s owner inactivity", elapsed, quiet)
		}
		t.Logf("first model call followed %s owner inactivity", at.Sub(followupAt))
	case err := <-failures:
		t.Fatal(err)
	case note := <-notes:
		t.Fatalf("investigation ended before the model ran: %s", note)
	case <-artifact.done:
		t.Fatalf("artifact exited: %v\n%s", artifact.err, artifact.logs.String())
	case <-ctx.Done():
		t.Fatalf("model was not called: %v\n%s", ctx.Err(), artifact.logs.String())
	}
	select {
	case note := <-notes:
		if !strings.Contains(note, artifactFinalNote) {
			t.Fatalf("unexpected staff note: %s", note)
		}
	case err := <-failures:
		t.Fatal(err)
	case <-artifact.done:
		t.Fatalf("artifact exited: %v\n%s", artifact.err, artifact.logs.String())
	case <-ctx.Done():
		t.Fatalf("staff note was not posted: %v\n%s", ctx.Err(), artifact.logs.String())
	}
	select {
	case err := <-failures:
		t.Fatal(err)
	default:
	}
	modelState.mu.Lock()
	steps, triages := modelState.step, modelState.triages
	modelState.mu.Unlock()
	if steps != len(artifactTools) || triages != 1 {
		t.Fatalf("model trajectory: %d/%d tools, %d triage calls", steps, len(artifactTools), triages)
	}
	if downloads.Load() != 1 || unsafeDownloads.Load() != 0 {
		t.Fatalf("attachment fetches: canonical=%d unsafe=%d", downloads.Load(), unsafeDownloads.Load())
	}
	artifact.assertNotExecuted(t, ctx, executionMarker)
	if strings.Contains(artifact.logs.String(), artifactAttachmentMarker) {
		t.Fatal("attachment contents entered artifact logs")
	}
	postArtifact(t, ctx, client, address+"/internal/investigations/tickets/"+artifactThread+"/activity", ticket.Activity{AuthorID: artifactOwner, MessageID: "12345678901234574"}, http.StatusNoContent)
	select {
	case note := <-notes:
		t.Fatalf("activity after completion posted an extra note: %s", note)
	case err := <-failures:
		t.Fatal(err)
	case <-artifact.done:
		t.Fatalf("artifact exited during completion observation: %v\n%s", artifact.err, artifact.logs.String())
	case <-ctx.Done():
		t.Fatalf("completion observation interrupted: %v", ctx.Err())
	case <-time.After(quiet + artifactObservationMargin):
	}
}

func artifactPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	if err := listener.Close(); err != nil {
		t.Fatal(err)
	}
	return port
}

func postArtifact(t *testing.T, ctx context.Context, client *http.Client, address string, value any, status int) {
	t.Helper()
	body, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, address, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("X-Internal-Secret", artifactSecret)
	request.Header.Set("Content-Type", "application/json")
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = response.Body.Close() }()
	if response.StatusCode != status {
		detail, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
		t.Fatalf("POST %s returned %d: %s", address, response.StatusCode, detail)
	}
}

func waitArtifactReady(t *testing.T, ctx context.Context, client *http.Client, address string, artifact *runningArtifact, failures <-chan error) {
	t.Helper()
	readyCtx, cancel := context.WithTimeout(ctx, artifactStartupTimeout)
	defer cancel()
	for {
		request, err := http.NewRequestWithContext(readyCtx, http.MethodGet, address+"/internal/users/"+artifactUser+"/versions", nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("X-Internal-Secret", artifactSecret)
		response, err := client.Do(request)
		if err == nil {
			_, _ = io.Copy(io.Discard, response.Body)
			_ = response.Body.Close()
			if response.StatusCode == http.StatusOK {
				return
			}
		}
		select {
		case <-artifact.done:
			t.Fatalf("artifact exited before readiness: %v\n%s", artifact.err, artifact.logs.String())
		case err := <-failures:
			t.Fatal(err)
		case <-readyCtx.Done():
			t.Fatalf("artifact did not become ready: %v\n%s", readyCtx.Err(), artifact.logs.String())
		case <-time.After(25 * time.Millisecond):
		}
	}
}

type artifactOutput struct {
	mu   sync.Mutex
	data bytes.Buffer
}

func (b *artifactOutput) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.data.Write(data)
}
func (b *artifactOutput) String() string { b.mu.Lock(); defer b.mu.Unlock(); return b.data.String() }

type runningArtifact struct {
	name   string
	binary bool
	done   chan struct{}
	err    error
	logs   artifactOutput
}

func startArtifact(t *testing.T, ctx context.Context, image, binary, caPath string, variables []string) *runningArtifact {
	t.Helper()
	artifact := &runningArtifact{name: "columbo-artifact-" + strconv.FormatInt(time.Now().UnixNano(), 10), binary: binary != "", done: make(chan struct{})}
	var command *exec.Cmd
	if binary != "" {
		path, err := filepath.Abs(binary)
		if err != nil {
			t.Fatal(err)
		}
		command = exec.CommandContext(ctx, path)
		command.Env = artifactEnvironment(append(variables, "SSL_CERT_FILE="+caPath))
	} else {
		arguments := []string{"run", "--rm", "--name", artifact.name, "--network", "host", "--memory", "256m", "--mount", "type=bind,source=" + caPath + ",target=/test-ca.crt,readonly"}
		for _, variable := range append(variables, "SSL_CERT_FILE=/test-ca.crt") {
			arguments = append(arguments, "-e", variable)
		}
		command = exec.CommandContext(ctx, "docker", append(arguments, image)...)
	}
	command.Dir = t.TempDir()
	command.Stdout = &artifact.logs
	command.Stderr = &artifact.logs
	if err := command.Start(); err != nil {
		t.Fatalf("start artifact: %v", err)
	}
	go func() { artifact.err = command.Wait(); close(artifact.done) }()
	t.Cleanup(func() {
		if artifact.binary {
			select {
			case <-artifact.done:
			default:
				_ = command.Process.Signal(os.Interrupt)
			}
		} else {
			cleanupCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = exec.CommandContext(cleanupCtx, "docker", "stop", "--time", "1", artifact.name).Run()
			_ = exec.CommandContext(cleanupCtx, "docker", "rm", artifact.name).Run()
		}
		select {
		case <-artifact.done:
		case <-time.After(5 * time.Second):
			_ = command.Process.Kill()
			<-artifact.done
		}
		if t.Failed() {
			t.Logf("artifact output:\n%s", artifact.logs.String())
		}
	})
	return artifact
}

func artifactEnvironment(variables []string) []string {
	environment := make([]string, 0, len(os.Environ())+len(variables))
	for _, variable := range os.Environ() {
		name, _, _ := strings.Cut(variable, "=")
		if strings.HasPrefix(name, "COLUMBO_") || strings.HasPrefix(name, "OTLP_") || strings.HasPrefix(name, "OPENROUTER_") || strings.HasPrefix(name, "O11Y_") {
			continue
		}
		switch name {
		case "INTERNAL_SECRET", "FUTO_BACKUPS_BOT_URL", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE":
			continue
		}
		environment = append(environment, variable)
	}
	return append(environment, variables...)
}

func (a *runningArtifact) assertNotExecuted(t *testing.T, ctx context.Context, name string) {
	t.Helper()
	if a.binary {
		if _, err := os.Stat(name); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("attached script execution marker exists: %v", err)
		}
		return
	}
	checkCtx, cancel := context.WithTimeout(ctx, artifactHTTPTimeout)
	defer cancel()
	if output, err := exec.CommandContext(checkCtx, "docker", "exec", a.name, "test", "!", "-e", name).CombinedOutput(); err != nil {
		t.Fatalf("attached script marker check: %v %s", err, output)
	}
}
