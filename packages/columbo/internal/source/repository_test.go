package source

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"testing/fstest"
	"unicode/utf8"
)

func fixtureGit(t *testing.T, repository string, args ...string) string {
	t.Helper()
	command := exec.Command("git", append([]string{"-C", repository, "-c", "user.name=Source fixture", "-c", "user.email=source@example.test"}, args...)...)
	data, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %s: %v", args, data, err)
	}
	return strings.TrimSpace(string(data))
}
func writeFiles(t *testing.T, repository string, files map[string]string) {
	t.Helper()
	for name, text := range files {
		filename := filepath.Join(repository, name)
		if err := os.MkdirAll(filepath.Dir(filename), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filename, []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	fixtureGit(t, repository, "add", ".")
}
func newSnapshot(t *testing.T, files map[string]string) (*Repository, string) {
	t.Helper()
	directory := t.TempDir()
	fixtureGit(t, directory, "init", "-b", "main")
	writeFiles(t, directory, files)
	fixtureGit(t, directory, "commit", "-m", "fixture")
	repository, err := Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	return repository, directory
}
func sourceFixture(t *testing.T) (*Repository, Manifest, string) {
	t.Helper()
	_, directory := newSnapshot(t, map[string]string{"src/client.go": "package client\nfunc fixed() bool {\nreturn false\n}\n", "deleted.md": "old content\n"})
	fixtureGit(t, directory, "commit", "--amend", "-m", "initial release")
	fixtureGit(t, directory, "tag", "v1.0.0")
	if err := os.Remove(filepath.Join(directory, "deleted.md")); err != nil {
		t.Fatal(err)
	}
	writeFiles(t, directory, map[string]string{"src/client.go": "package client\nfunc fixed() bool {\nreturn true\n}\n", "docs/CHANGELOG.md": "fix retry\nfix timeout\n"})
	fixtureGit(t, directory, "commit", "-m", "fix retry")
	repository, err := Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	return repository, repository.manifest, directory
}

func TestReadFileUsesExactVersionAndPaginatesLines(t *testing.T) {
	repository, manifest, _ := sourceFixture(t)
	for _, ref := range []string{"1.0.0", "v1.0.0", "refs/tags/v1.0.0", manifest.Revisions[1].Commit} {
		page, err := repository.ReadFile(ref, "src/client.go", 2, 2)
		if err != nil {
			t.Fatal(err)
		}
		if page.Revision.Ref != "v1.0.0" || page.TotalLines != 4 || len(page.Lines) != 2 || page.Lines[0].Number != 2 || page.Lines[1].Text != "return false" || page.NextLine != 4 {
			t.Fatalf("unexpected page for %s: %+v", ref, page)
		}
	}
	if _, err := repository.ReadFile("9.9.9", "src/client.go", 1, 1); err == nil || !strings.Contains(err.Error(), "unavailable") {
		t.Fatalf("unknown version should fail without HEAD substitution: %v", err)
	}
	page, err := repository.ReadFile("", "src/client.go", 3, 1)
	if err != nil || len(page.Lines) != 1 || page.Lines[0].Text != "return true" {
		t.Fatalf("omitted ref should explicitly use HEAD: %+v %v", page, err)
	}
}

func TestSourceRejectsPathTraversalAndInvalidBounds(t *testing.T) {
	repository, _, _ := sourceFixture(t)
	for _, filename := range []string{"../src/client.go", "/src/client.go", "src/../client.go", "src\\client.go", ".git/config", "src//client.go", "src/\x00client.go"} {
		t.Run(filename, func(t *testing.T) {
			if _, err := repository.ReadFile("HEAD", filename, 1, 1); err == nil {
				t.Fatal("invalid path accepted")
			}
			if _, err := repository.ListFiles("HEAD", filename, 0, 10); err == nil {
				t.Fatal("invalid prefix accepted")
			}
		})
	}
	if _, err := repository.ReadFile("HEAD", "src/client.go", -1, 1); err == nil {
		t.Fatal("negative line accepted")
	}
	if _, err := repository.ListFiles("HEAD", "", -1, 10); err == nil {
		t.Fatal("negative offset accepted")
	}
}

func TestExactTagTakesPrecedenceOverVersionAlias(t *testing.T) {
	_, _, directory := sourceFixture(t)
	fixtureGit(t, directory, "tag", "1.0.0")
	repository, err := Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	page, err := repository.ReadFile("1.0.0", "src/client.go", 3, 1)
	if err != nil || page.Revision.Ref != "1.0.0" || len(page.Lines) != 1 || page.Lines[0].Text != "return true" {
		t.Fatalf("version alias shadowed an exact tag: %+v %v", page, err)
	}
}

func TestExactTagOutsideTheRevisionIndexTakesPrecedenceOverVersionAlias(t *testing.T) {
	_, _, directory := sourceFixture(t)
	fixtureGit(t, directory, "tag", "1.0.0")
	exactCommit := fixtureGit(t, directory, "rev-parse", "1.0.0")
	for i := range MaxRevisions - 2 {
		fixtureGit(t, directory, "tag", fmt.Sprintf("v2.0.%d", i))
	}
	repository, err := Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	prefixed, err := repository.revision("v1.0.0")
	if err != nil {
		t.Fatal(err)
	}
	repository.manifest.Revisions[MaxRevisions-1] = prefixed
	repository.manifest.OmittedRefs = []string{"1.0.0"}
	if repository.manifest.DiscoveredTags != MaxRevisions {
		t.Fatalf("fixture does not cross the release index limit: %+v", repository.Metadata())
	}

	page, err := repository.ReadFile("1.0.0", "src/client.go", 3, 1)

	if err != nil || page.Revision.Ref != "1.0.0" || page.Revision.Commit != exactCommit || len(page.Lines) != 1 || page.Lines[0].Text != "return true" {
		t.Fatalf("indexed alias shadowed an omitted exact tag: %+v %v", page, err)
	}
}

func TestListFilesScopesDirectoriesAndReturnsNextOffset(t *testing.T) {
	repository, _, _ := sourceFixture(t)
	page, err := repository.ListFiles("HEAD", "", 0, 1)
	if err != nil || page.Total != 2 || len(page.Files) != 1 || page.NextOffset != 1 || page.Files[0] != "docs/CHANGELOG.md" {
		t.Fatalf("unexpected file list: %+v %v", page, err)
	}
	page, err = repository.ListFiles("HEAD", "src/", 0, 1000)
	if err != nil || page.Total != 1 || len(page.Files) != 1 || page.Files[0] != "src/client.go" {
		t.Fatalf("unexpected scoped file list: %+v %v", page, err)
	}
	page, err = repository.ListFiles("HEAD", "sr", 0, 1)
	if err != nil || page.Total != 0 {
		t.Fatalf("prefix matched unrelated directory: %+v %v", page, err)
	}
}

func TestSearchIsLiteralBoundedAndVersionSpecific(t *testing.T) {
	repository, _, _ := sourceFixture(t)
	result, err := repository.Search("HEAD", "fix", "docs", 1)
	if err != nil || len(result.Matches) != 1 || !result.Truncated || result.Matches[0].Number != 1 || result.Matches[0].Path != "docs/CHANGELOG.md" {
		t.Fatalf("unexpected bounded search: %+v %v", result, err)
	}
	result, err = repository.Search("1.0.0", "return true", "src", 10)
	if err != nil || len(result.Matches) != 0 || result.Truncated {
		t.Fatalf("search silently substituted HEAD: %+v %v", result, err)
	}
	result, err = repository.Search("HEAD", ".*", "", 10)
	if err != nil || len(result.Matches) != 0 {
		t.Fatalf("search interpreted regex: %+v %v", result, err)
	}
	for _, query := range []string{"", "a\nb", strings.Repeat("a", MaxSearchQueryBytes+1)} {
		if _, err := repository.Search("HEAD", query, "", 1); err == nil {
			t.Fatalf("invalid query accepted: %q", query)
		}
	}
}

func TestSearchRetainsLateLiteralMatchesInBoundedUTF8Excerpts(t *testing.T) {
	for _, test := range []struct {
		name      string
		query     string
		text      string
		truncated bool
	}{
		{"late literal", "needle", strings.Repeat("x", MaxLineBytes+100) + "needle" + strings.Repeat("x", MaxLineBytes), true},
		{"multibyte context", "needle", strings.Repeat("界", MaxLineBytes) + "needle" + strings.Repeat("🙂", MaxLineBytes), true},
		{"maximum multibyte literal", strings.Repeat("🙂", MaxSearchQueryBytes/len("🙂")), strings.Repeat("界", MaxLineBytes) + strings.Repeat("🙂", MaxSearchQueryBytes/len("🙂")) + strings.Repeat("界", MaxLineBytes), true},
		{"short line", "needle", "prefix needle suffix", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			text := "first line\n" + test.text + "\n"
			repository, _ := newSnapshot(t, map[string]string{"src/long.ts": text})

			result, err := repository.Search("HEAD", test.query, "src", 1)

			if err != nil || len(result.Matches) != 1 {
				t.Fatalf("source literal not found: %+v %v", result, err)
			}
			match := result.Matches[0]
			if match.Number != 2 || match.Path != "src/long.ts" || !strings.Contains(match.Text, test.query) || len(match.Text) > MaxLineBytes || !utf8.ValidString(match.Text) || match.Truncated != test.truncated {
				t.Fatalf("search excerpt lost its literal or UTF-8 bounds: %+v", match)
			}
			if !test.truncated && match.Text != test.text {
				t.Fatalf("short source line was changed: %q", match.Text)
			}
		})
	}
}

func TestCompareReturnsExactSourceEvidenceAndUnavailableMissingSides(t *testing.T) {
	repository, _, _ := sourceFixture(t)
	result, err := repository.Compare("1.0.0", "HEAD", "src/client.go", 0, 100)
	if err != nil || result.Status != "modified" || result.From.Lines[2].Text != "return false" || result.To.Lines[2].Text != "return true" {
		t.Fatalf("unexpected comparison: %+v %v", result, err)
	}
	for _, test := range []struct{ path, status string }{{"docs/CHANGELOG.md", "unavailable"}, {"deleted.md", "unavailable"}} {
		result, err := repository.Compare("1.0.0", "HEAD", test.path, 0, 10)
		if err != nil || result.Status != test.status {
			t.Fatalf("unexpected %s: %+v %v", test.status, result, err)
		}
	}
	result, err = repository.Compare("HEAD", "HEAD", "src/client.go", 0, 10)
	if err != nil || result.Status != "unchanged" {
		t.Fatalf("unexpected unchanged comparison: %+v %v", result, err)
	}
	if _, err := repository.Compare("2.0.0", "HEAD", "src/client.go", 0, 10); err == nil {
		t.Fatal("unknown comparison version accepted")
	}
}

func TestReleaseHistoryPreservesCoverageAndMetadataOmitsContent(t *testing.T) {
	repository, _, _ := sourceFixture(t)
	result, err := repository.ReleaseLog("v1.0.0", 0, 1)
	if err != nil || len(result.Commits) != 1 || result.Commits[0].Subject != "initial release" || !result.Revision.HistoryComplete || result.Revision.Files != nil {
		t.Fatalf("unexpected release history: %+v %v", result, err)
	}
	metadata := repository.Metadata()
	if metadata.Revisions[0].Files != nil || metadata.Revisions[1].Commits != nil {
		t.Fatal("metadata exposes entire snapshots")
	}
	metadata.Revisions[0].Ref = "changed"
	if repository.Metadata().Revisions[0].Ref != "HEAD" {
		t.Fatal("metadata is mutable")
	}
}

func TestOpenRejectsMissingOrCorruptGitData(t *testing.T) {
	for _, files := range []fstest.MapFS{
		{},
		{"HEAD": &fstest.MapFile{Data: []byte("invalid\n")}},
		{"HEAD": &fstest.MapFile{Data: []byte(strings.Repeat("a", 40) + "\n")}, "config": &fstest.MapFile{Data: []byte("[core]\nbare = true\n")}},
	} {
		if _, err := Open(files); err == nil {
			t.Fatal("invalid Git repository accepted")
		}
	}
}

func TestReadsArbitraryEmbeddedCommitOutsideTagIndex(t *testing.T) {
	_, _, directory := sourceFixture(t)
	middle := fixtureGit(t, directory, "rev-parse", "HEAD")
	writeFiles(t, directory, map[string]string{"src/client.go": "package client\nconst Updated=true\n"})
	fixtureGit(t, directory, "commit", "-m", "later change")
	repository, err := Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	page, err := repository.ReadFile(middle, "src/client.go", 3, 1)
	if err != nil || page.Revision.Commit != middle || len(page.Lines) != 1 || page.Lines[0].Text != "return true" {
		t.Fatalf("arbitrary commit missing: %+v %v", page, err)
	}
	history, err := repository.ReleaseLog(middle, 0, 10)
	if err != nil || len(history.Commits) != 2 || history.Commits[0].Subject != "fix retry" {
		t.Fatalf("commit history unavailable: %+v %v", history, err)
	}
}

func TestRepositoryFiltersNonSourceAndOversizedContent(t *testing.T) {
	repository, _ := newSnapshot(t, map[string]string{"src/client.go": "package client\n", ".env": "SECRET=data", "src/client_test.go": "test", "src/binary.go": "\x00binary", "src/generated.go": "// Code generated by fixture. DO NOT EDIT.\npackage fixture", "src/huge.go": strings.Repeat("x", MaxFileBytes+1)})
	files, err := repository.ListFiles("HEAD", "", 0, 10)
	if err != nil || len(files.Files) != 1 || files.Files[0] != "src/client.go" || files.Revision.Complete || files.Revision.SkippedFiles != 1 {
		t.Fatalf("source filters failed: %+v %v", files, err)
	}
	for _, name := range []string{".env", "src/client_test.go", "src/binary.go", "src/generated.go", "src/huge.go"} {
		if _, err := repository.ReadFile("HEAD", name, 1, 1); err == nil {
			t.Fatalf("excluded source read: %s", name)
		}
	}
}

func TestFilePageCapsLinesBytesAndKeepsUTF8Valid(t *testing.T) {
	data := []byte(strings.Repeat(strings.Repeat("界", MaxLineBytes)+"\n", MaxLineCount+10))
	page, err := filePage(Revision{}, "large.ts", data, 1, 10000)
	if err != nil || len(page.Lines) > MaxLineCount || page.NextLine == 0 || len(page.Lines)*MaxLineBytes > MaxExcerptBytes || !page.Lines[0].Truncated || len(page.Lines[0].Text) > MaxLineBytes || !utf8.ValidString(page.Lines[0].Text) {
		t.Fatalf("excerpt is not bounded: %+v %v", page, err)
	}
}

func TestVersionAliasesOutsideBoundedTagIndex(t *testing.T) {
	_, directory := newSnapshot(t, map[string]string{"src/version.go": "package version\n"})
	for i := range MaxRevisions {
		fixtureGit(t, directory, "tag", fmt.Sprintf("v0.0.%d", i))
	}
	repository, err := Open(os.DirFS(filepath.Join(directory, ".git")))
	if err != nil {
		t.Fatal(err)
	}
	metadata := repository.Metadata()
	if len(metadata.OmittedRefs) != 1 || metadata.OmittedRefs[0] != "v0.0.0" {
		t.Fatalf("unexpected bounded index: %+v", metadata.OmittedRefs)
	}
	for _, ref := range []string{"v0.0.0", "0.0.0", "refs/tags/v0.0.0"} {
		page, err := repository.ReadFile(ref, "src/version.go", 1, 1)
		if err != nil || page.Revision.Ref != "v0.0.0" {
			t.Fatalf("omitted tag alias unavailable: %+v %v", page, err)
		}
	}
}
