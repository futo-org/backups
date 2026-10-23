package agent

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"columbo/internal/source"

	"github.com/cloudwego/eino/components/tool"
)

func sourceBox(t *testing.T, maxCalls, maxResult int) *toolbox {
	t.Helper()
	directory := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", directory, "-c", "user.name=Source fixture", "-c", "user.email=source@example.test"}, args...)...)
		data, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %s: %v", args, data, err)
		}
	}
	git("init", "-b", "main")
	if err := os.MkdirAll(filepath.Join(directory, "src"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, "src", "main.go"), []byte("package source\nconst Fixed = true\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "-m", "fixture")
	repository, err := source.Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	box := testBox(maxCalls, maxResult)
	box.source = repository
	return box
}

func TestSourceToolsUseSharedBudgetAndStoreLargeJSON(t *testing.T) {
	box := sourceBox(t, 1, 10)
	result, err := box.sourceRead(context.Background(), sourceReadArgs{Ref: "HEAD", Path: "src/main.go"})
	if err != nil || !strings.Contains(result, "stored as r1") {
		t.Fatalf("source result was not stored: %q %v", result, err)
	}
	stored, exists := box.store.Get("r1")
	if !exists || !json.Valid([]byte(stored)) || !strings.Contains(stored, "Fixed = true") {
		t.Fatalf("source stored result is not complete JSON: %q", stored)
	}
	if _, err := box.queryLogs(context.Background(), logsArgs{Query: "error"}); !errors.Is(err, errToolBudget) {
		t.Fatalf("telemetry did not share source budget: %v", err)
	}
	if box.callsMade() != 1 || len(box.queriesRun()) != 1 {
		t.Fatalf("source audit budget is incorrect: %d %v", box.callsMade(), box.queriesRun())
	}
}

func TestSourceToolRegistrationAndUnavailableVersionsBecomeResults(t *testing.T) {
	box := sourceBox(t, 10, 8192)
	tools, err := box.tools()
	if err != nil || len(tools) != 10 {
		t.Fatalf("source tools not registered: %d %v", len(tools), err)
	}
	for _, candidate := range tools {
		info, err := candidate.Info(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if info.Name != "read_source_file" {
			continue
		}
		invoke := candidate.(tool.InvokableTool)
		result, err := invoke.InvokableRun(context.Background(), `{"ref":"9.9.9","path":"src/main.go"}`)
		if err != nil || !strings.Contains(result, "ERROR:") || !strings.Contains(result, "unavailable") || strings.Contains(result, "Fixed = true") {
			t.Fatalf("missing version did not remain an unavailable tool result: %q %v", result, err)
		}
		return
	}
	t.Fatal("source read tool missing")
}

func TestSourceToolsReturnVersionedJSONForEveryOperation(t *testing.T) {
	box := sourceBox(t, 10, 8192)
	ctx := context.Background()
	for _, action := range []func() (string, error){
		func() (string, error) { return box.sourceRevisions(ctx, sourceRevisionsArgs{}) },
		func() (string, error) { return box.sourceFiles(ctx, sourceFilesArgs{Ref: "HEAD", PathPrefix: "src"}) },
		func() (string, error) { return box.sourceSearch(ctx, sourceSearchArgs{Ref: "HEAD", Query: "Fixed"}) },
		func() (string, error) {
			return box.sourceCompare(ctx, sourceCompareArgs{From: "HEAD", To: "HEAD", Path: "src/main.go"})
		},
		func() (string, error) { return box.sourceHistory(ctx, sourceHistoryArgs{Ref: "HEAD"}) },
	} {
		result, err := action()
		if err != nil || !json.Valid([]byte(result)) || !strings.Contains(result, "HEAD") {
			t.Fatalf("invalid versioned source result: %q %v", result, err)
		}
	}
	if !strings.Contains(box.sourceContext(), "shallow history=false") || !strings.Contains(box.sourceContext(), "never silently substitute HEAD") {
		t.Fatalf("source coverage missing from prompt: %q", box.sourceContext())
	}
	if _, err := box.sourceCompare(ctx, sourceCompareArgs{To: "HEAD", Path: "src/main.go"}); err == nil {
		t.Fatal("comparison accepted implicit source release")
	}
	if _, err := box.sourceHistory(ctx, sourceHistoryArgs{}); err == nil {
		t.Fatal("history accepted implicit release")
	}
}

func TestMissingSourceDoesNotRegisterToolsAndReportsUnavailable(t *testing.T) {
	box := testBox(10, 8192)
	tools, err := box.sourceTools()
	if err != nil || len(tools) != 0 || !strings.Contains(box.sourceContext(), "unavailable") {
		t.Fatalf("missing source not handled: %d %q %v", len(tools), box.sourceContext(), err)
	}
	if _, err := box.sourceRevisions(context.Background(), sourceRevisionsArgs{}); err == nil {
		t.Fatal("missing source accepted")
	}
}
