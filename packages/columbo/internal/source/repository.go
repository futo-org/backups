package source

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/cache"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/storage/filesystem"
	"golang.org/x/mod/semver"
)

var (
	commitPattern = regexp.MustCompile(`^[a-f0-9]{40}$`)
	refPattern    = regexp.MustCompile(`^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$`)
)

type Repository struct {
	git      *git.Repository
	manifest Manifest
}

func Open(files fs.FS) (*Repository, error) {
	storage := filesystem.NewStorageWithOptions(newReadOnlyFS(files), cache.NewObjectLRU(maxDecodeCacheBytes), filesystem.Options{ExclusiveAccess: true, LargeObjectThreshold: maxDecodedRepositoryBytes})
	snapshot, err := memoryRepository(storage)
	if err != nil {
		return nil, err
	}
	repository, err := git.Open(snapshot, nil)
	if err != nil {
		return nil, fmt.Errorf("open embedded Git repository: %w", err)
	}
	r := &Repository{git: repository}
	if err := r.load(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *Repository) load() error {
	head, err := r.git.Head()
	if err != nil {
		return err
	}
	shallow, err := r.git.Storer.Shallow()
	if err != nil {
		return err
	}
	r.manifest = Manifest{Format: ArchiveFormat, Head: head.Hash().String(), Shallow: len(shallow) > 0, Selection: "Build-time HEAD and semantic-version tags; any embedded commit can be read by its full hash", Excluded: exclusions, MaxFileBytes: MaxFileBytes}
	tags, err := r.git.Tags()
	if err != nil {
		return err
	}
	var refs []string
	err = tags.ForEach(func(ref *plumbing.Reference) error {
		name := ref.Name().Short()
		if refPattern.MatchString(name) {
			refs = append(refs, name)
		}
		return nil
	})
	if err != nil {
		return err
	}
	sort.Slice(refs, func(i, j int) bool { return semver.Compare(normalizeVersion(refs[i]), normalizeVersion(refs[j])) > 0 })
	r.manifest.DiscoveredTags = len(refs)
	if len(refs) >= MaxRevisions {
		r.manifest.OmittedRefs = append([]string(nil), refs[MaxRevisions-1:]...)
		refs = refs[:MaxRevisions-1]
	}
	refs = append([]string{"HEAD"}, refs...)
	for _, ref := range refs {
		rev, err := r.revision(ref)
		if err != nil && refPattern.MatchString(ref) && !strings.HasPrefix(ref, "v") {
			rev, err = r.revision("v" + ref)
		}
		if err != nil {
			return err
		}
		r.manifest.Revisions = append(r.manifest.Revisions, rev)
	}
	for i := range r.manifest.Revisions {
		rev := &r.manifest.Revisions[i]
		for _, candidate := range r.manifest.Revisions[i+1:] {
			older, err := r.git.CommitObject(plumbing.NewHash(candidate.Commit))
			if err != nil {
				return err
			}
			newer, err := r.git.CommitObject(plumbing.NewHash(rev.Commit))
			if err != nil {
				return err
			}
			ancestor, err := older.IsAncestor(newer)
			if err != nil && !r.manifest.Shallow {
				return err
			}
			if ancestor {
				rev.HistoryBase = candidate.Ref
				break
			}
		}
		if err := r.history(rev); err != nil {
			return err
		}
	}
	return nil
}

func normalizeVersion(ref string) string { return "v" + strings.TrimPrefix(ref, "v") }

func (r *Repository) revision(ref string) (Revision, error) {
	target := ref
	if refPattern.MatchString(ref) {
		target = "refs/tags/" + ref
	}
	hash, err := r.git.ResolveRevision(plumbing.Revision(target))
	if err != nil {
		return Revision{}, fmt.Errorf("source revision %q unavailable in this build; no version substitution was made: %w", ref, err)
	}
	commit, err := r.git.CommitObject(*hash)
	if err != nil {
		return Revision{}, err
	}
	tree, err := commit.Tree()
	if err != nil {
		return Revision{}, err
	}
	rev := Revision{Ref: ref, Commit: hash.String(), CommittedAt: commit.Committer.When.UTC().Format(time.RFC3339), Complete: true, Files: make(map[string]string)}
	if ref != "HEAD" && refPattern.MatchString(ref) {
		rev.Version = strings.TrimPrefix(ref, "v")
	}
	err = tree.Files().ForEach(func(file *object.File) error {
		if !IncludePath(file.Name) || file.Mode != filemode.Regular && file.Mode != filemode.Executable {
			rev.ExcludedFiles++
			return nil
		}
		if file.Size > MaxFileBytes || len(rev.Files) >= MaxRevisionFiles {
			rev.SkippedFiles++
			rev.Complete = false
			return nil
		}
		data, err := readBlob(file)
		if err != nil {
			return err
		}
		if !utf8.Valid(data) || bytes.ContainsRune(data, '\x00') || generated(data) {
			rev.ExcludedFiles++
			return nil
		}
		rev.Files[file.Name] = file.Hash.String()
		return nil
	})
	rev.FileCount = len(rev.Files)
	return rev, err
}

func (r *Repository) history(revision *Revision) error {
	revision.HistorySelection = "First-parent commit subjects, newest first, capped at 100 commits"
	commit, err := r.git.CommitObject(plumbing.NewHash(revision.Commit))
	if err != nil {
		return err
	}
	base := ""
	for _, candidate := range r.manifest.Revisions {
		if candidate.Ref == revision.HistoryBase {
			base = candidate.Commit
		}
	}
	revision.HistoryComplete = !r.manifest.Shallow
	for commit != nil && commit.Hash.String() != base {
		if len(revision.Commits) == MaxReleaseCommits {
			revision.HistoryComplete = false
			break
		}
		revision.Commits = append(revision.Commits, Commit{Hash: commit.Hash.String(), CommittedAt: commit.Committer.When.UTC().Format(time.RFC3339), Subject: strings.SplitN(commit.Message, "\n", 2)[0]})
		if commit.NumParents() == 0 {
			break
		}
		commit, err = commit.Parent(0)
		if err != nil {
			if r.manifest.Shallow {
				revision.HistoryComplete = false
				break
			}
			return err
		}
	}
	return nil
}

func (r *Repository) Metadata() Manifest {
	metadata := r.manifest
	metadata.OmittedRefs = append([]string(nil), metadata.OmittedRefs...)
	metadata.Revisions = make([]Revision, len(r.manifest.Revisions))
	for i, rev := range r.manifest.Revisions {
		metadata.Revisions[i] = revisionSummary(rev)
	}
	return metadata
}

func (r *Repository) resolve(ref string) (Revision, error) {
	if ref == "" {
		ref = "HEAD"
	}
	ref = strings.TrimPrefix(ref, "refs/tags/")
	for _, rev := range r.manifest.Revisions {
		if ref == rev.Ref || ref == rev.Commit || ref == "refs/tags/"+rev.Ref {
			return rev, nil
		}
	}
	exactTagExists := false
	if refPattern.MatchString(ref) {
		_, err := r.git.Reference(plumbing.NewTagReferenceName(ref), true)
		if err != nil && !errors.Is(err, plumbing.ErrReferenceNotFound) {
			return Revision{}, err
		}
		exactTagExists = err == nil
	}
	for _, rev := range r.manifest.Revisions {
		if !exactTagExists && rev.Version != "" && ref == rev.Version {
			return rev, nil
		}
	}
	if commitPattern.MatchString(ref) || refPattern.MatchString(ref) {
		rev, err := r.revision(ref)
		if err != nil && refPattern.MatchString(ref) && !strings.HasPrefix(ref, "v") {
			rev, err = r.revision("v" + ref)
		}
		if err != nil {
			return Revision{}, err
		}
		if err := r.history(&rev); err != nil {
			return Revision{}, err
		}
		return rev, nil
	}
	return Revision{}, fmt.Errorf("source revision %q unavailable in this build; use an embedded tag or full commit hash; no version substitution was made", ref)
}

func (r *Repository) ListFiles(ref, prefix string, offset, limit int) (FileList, error) {
	revision, err := r.resolve(ref)
	if err != nil {
		return FileList{}, err
	}
	prefix = strings.TrimSuffix(prefix, "/")
	if err := validatePath(prefix, true); err != nil {
		return FileList{}, err
	}
	files := filenames(revision, prefix)
	start, end, next, err := pageBounds(len(files), offset, limit)
	if err != nil {
		return FileList{}, err
	}
	return FileList{Revision: revisionSummary(revision), PathPrefix: prefix, Files: files[start:end], Total: len(files), NextOffset: next}, nil
}

func (r *Repository) ReadFile(ref, filename string, startLine, lineCount int) (FilePage, error) {
	revision, err := r.resolve(ref)
	if err != nil {
		return FilePage{}, err
	}
	data, err := r.read(revision, filename)
	if err != nil {
		return FilePage{}, err
	}
	return filePage(revision, filename, data, startLine, lineCount)
}

func (r *Repository) Search(ref, query, prefix string, limit int) (SearchResult, error) {
	revision, err := r.resolve(ref)
	if err != nil {
		return SearchResult{}, err
	}
	if query == "" || len(query) > MaxSearchQueryBytes || !utf8.ValidString(query) || strings.ContainsAny(query, "\x00\r\n") {
		return SearchResult{}, fmt.Errorf("source search requires a single-line literal of 1 to %d bytes", MaxSearchQueryBytes)
	}
	prefix = strings.TrimSuffix(prefix, "/")
	if err := validatePath(prefix, true); err != nil {
		return SearchResult{}, err
	}
	if limit <= 0 {
		limit = DefaultSearchLimit
	}
	if limit > MaxSearchLimit {
		limit = MaxSearchLimit
	}
	result := SearchResult{Revision: revisionSummary(revision), Query: query, PathPrefix: prefix, Matches: []SearchMatch{}}
	bytesRead := 0
	for _, filename := range filenames(revision, prefix) {
		data, err := r.read(revision, filename)
		if err != nil {
			return SearchResult{}, err
		}
		bytesRead += len(data)
		if bytesRead > MaxSearchBytes {
			result.Truncated = true
			return result, nil
		}
		result.Scanned++
		for i, line := range sourceLines(data) {
			match := strings.Index(line, query)
			if match < 0 {
				continue
			}
			if len(result.Matches) == limit {
				result.Truncated = true
				return result, nil
			}
			start := 0
			if match+len(query) > MaxLineBytes {
				start = max(0, match-(MaxLineBytes-len(query))/2)
				for !utf8.RuneStart(line[start]) {
					start--
				}
			}
			excerpt := sourceLine(i+1, line[start:])
			excerpt.Truncated = excerpt.Truncated || start > 0
			result.Matches = append(result.Matches, SearchMatch{Path: filename, Line: excerpt})
		}
	}
	return result, nil
}

func (r *Repository) Compare(from, to, filename string, startLine, lineCount int) (Comparison, error) {
	before, err := r.resolve(from)
	if err != nil {
		return Comparison{}, err
	}
	after, err := r.resolve(to)
	if err != nil {
		return Comparison{}, err
	}
	if err := validatePath(filename, false); err != nil {
		return Comparison{}, err
	}
	beforeHash, beforeExists := before.Files[filename]
	afterHash, afterExists := after.Files[filename]
	if !beforeExists && !afterExists {
		return Comparison{}, fmt.Errorf("source file %q unavailable in both revisions", filename)
	}
	result := Comparison{Path: filename, Status: "modified"}
	if !beforeExists || !afterExists {
		result.Status = "unavailable"
	} else if beforeHash == afterHash {
		result.Status = "unchanged"
	}
	var beforeData, afterData []byte
	if beforeExists {
		beforeData, err = r.read(before, filename)
		if err != nil {
			return Comparison{}, err
		}
	}
	if afterExists {
		afterData, err = r.read(after, filename)
		if err != nil {
			return Comparison{}, err
		}
	}
	if startLine == 0 {
		startLine = firstChangedLine(beforeData, afterData)
	}
	if beforeExists {
		page, err := filePage(before, filename, beforeData, startLine, lineCount)
		if err != nil {
			return Comparison{}, err
		}
		result.From = &page
	}
	if afterExists {
		page, err := filePage(after, filename, afterData, startLine, lineCount)
		if err != nil {
			return Comparison{}, err
		}
		result.To = &page
	}
	return result, nil
}

func (r *Repository) ReleaseLog(ref string, offset, limit int) (ReleaseHistory, error) {
	revision, err := r.resolve(ref)
	if err != nil {
		return ReleaseHistory{}, err
	}
	start, end, next, err := pageBounds(len(revision.Commits), offset, limit)
	if err != nil {
		return ReleaseHistory{}, err
	}
	commits := append([]Commit{}, revision.Commits[start:end]...)
	return ReleaseHistory{Revision: revisionSummary(revision), Commits: commits, Total: len(revision.Commits), NextOffset: next}, nil
}

func (r *Repository) read(revision Revision, filename string) ([]byte, error) {
	if err := validatePath(filename, false); err != nil {
		return nil, err
	}
	hash, exists := revision.Files[filename]
	if !exists {
		return nil, fmt.Errorf("source file %q unavailable at %s; excluded files cannot be read", filename, revision.Ref)
	}
	blob, err := r.git.BlobObject(plumbing.NewHash(hash))
	if err != nil {
		return nil, err
	}
	data, err := readBlob(&object.File{Blob: *blob})
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(data) || bytes.ContainsRune(data, '\x00') || generated(data) {
		return nil, fmt.Errorf("invalid source content for %q", filename)
	}
	return data, nil
}

func readBlob(file *object.File) ([]byte, error) {
	if file.Size > MaxFileBytes {
		return nil, fmt.Errorf("source file exceeds size limit")
	}
	reader, err := file.Reader()
	if err != nil {
		return nil, err
	}
	defer func() { _ = reader.Close() }()
	data, err := io.ReadAll(io.LimitReader(reader, MaxFileBytes+1))
	if len(data) > MaxFileBytes {
		return nil, fmt.Errorf("source file exceeds size limit")
	}
	return data, err
}

func validatePath(filename string, allowEmpty bool) error {
	if filename == "" && allowEmpty {
		return nil
	}
	if filename == "" || filename == "." || path.IsAbs(filename) || path.Clean(filename) != filename || strings.ContainsAny(filename, "\\\x00\r\n") || !utf8.ValidString(filename) {
		return fmt.Errorf("invalid source path %q", filename)
	}
	for _, segment := range strings.Split(filename, "/") {
		if segment == ".." || segment == ".git" {
			return fmt.Errorf("invalid source path %q", filename)
		}
	}
	return nil
}

func filenames(revision Revision, prefix string) []string {
	files := make([]string, 0, len(revision.Files))
	for filename := range revision.Files {
		if prefix == "" || filename == prefix || strings.HasPrefix(filename, prefix+"/") {
			files = append(files, filename)
		}
	}
	sort.Strings(files)
	return files
}

func revisionSummary(revision Revision) Revision {
	revision.Files = nil
	revision.Commits = nil
	return revision
}

func pageBounds(total, offset, limit int) (int, int, int, error) {
	if offset < 0 {
		return 0, 0, 0, fmt.Errorf("source offset must be nonnegative")
	}
	if offset > total {
		offset = total
	}
	if limit <= 0 {
		limit = DefaultPageSize
	}
	if limit > MaxPageSize {
		limit = MaxPageSize
	}
	end := min(offset+limit, total)
	next := 0
	if end < total {
		next = end
	}
	return offset, end, next, nil
}

func filePage(revision Revision, filename string, data []byte, startLine, lineCount int) (FilePage, error) {
	if startLine < 0 || lineCount < 0 {
		return FilePage{}, fmt.Errorf("source line bounds must be nonnegative")
	}
	if startLine == 0 {
		startLine = 1
	}
	if lineCount == 0 {
		lineCount = DefaultLineCount
	}
	if lineCount > MaxLineCount {
		lineCount = MaxLineCount
	}
	lines := sourceLines(data)
	page := FilePage{Revision: revisionSummary(revision), Path: filename, TotalLines: len(lines), Lines: []Line{}}
	start := min(startLine-1, len(lines))
	end := min(start+lineCount, len(lines))
	bytes := 0
	for i := start; i < end; i++ {
		line := sourceLine(i+1, lines[i])
		bytes += len(line.Text)
		if bytes > MaxExcerptBytes {
			page.NextLine = i + 1
			return page, nil
		}
		page.Lines = append(page.Lines, line)
	}
	if end < len(lines) {
		page.NextLine = end + 1
	}
	return page, nil
}

func sourceLines(data []byte) []string {
	if len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
}

func sourceLine(number int, text string) Line {
	text = strings.TrimSuffix(text, "\r")
	line := Line{Number: number, Text: text}
	if len(text) > MaxLineBytes {
		end := MaxLineBytes
		for !utf8.RuneStart(text[end]) {
			end--
		}
		line.Text = text[:end]
		line.Truncated = true
	}
	return line
}

func firstChangedLine(before, after []byte) int {
	a, b := sourceLines(before), sourceLines(after)
	i := 0
	for i < min(len(a), len(b)) && a[i] == b[i] {
		i++
	}
	return max(1, i-4)
}
