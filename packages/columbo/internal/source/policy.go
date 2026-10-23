package source

import (
	"path"
	"strings"
	"unicode/utf8"
)

const exclusions = "Only UTF-8 source, configuration, documentation and changelogs; excludes symlinks, binary files, secrets, dependencies, lockfiles, generated clients, tests, fixtures and build output"

func IncludePath(filename string) bool {
	if filename == "." || path.IsAbs(filename) || path.Clean(filename) != filename || strings.ContainsAny(filename, "\\\x00\r\n") || !utf8.ValidString(filename) {
		return false
	}
	for _, segment := range strings.Split(filename, "/") {
		switch strings.ToLower(segment) {
		case "..", ".git", "node_modules", "vendor", "dist", "build", "coverage", ".svelte-kit", ".turbo", ".cache", "generated", "__tests__", "__snapshots__", "tests", "test", "e2e", "fixtures", "testdata", "secrets":
			return false
		}
	}
	base := strings.ToLower(path.Base(filename))
	if strings.HasPrefix(base, ".env") || strings.Contains(base, "lock") && (strings.HasSuffix(base, ".yaml") || strings.HasSuffix(base, ".json") || strings.HasSuffix(base, ".lock")) || strings.HasSuffix(base, ".sum") || strings.HasSuffix(base, "_test.go") || strings.Contains(base, ".test.") || strings.Contains(base, ".spec.") || base == "fetch-client.ts" || strings.HasSuffix(base, ".min.js") || strings.HasSuffix(base, ".min.css") {
		return false
	}
	if strings.HasPrefix(base, "dockerfile") || base == "makefile" || base == "tiltfile" || base == "go.mod" || base == "license" || strings.HasPrefix(filename, ".mise/tasks/") {
		return true
	}
	switch strings.ToLower(path.Ext(filename)) {
	case ".go", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".svelte", ".json", ".yaml", ".yml", ".toml", ".md", ".mdx", ".txt", ".sql", ".sh", ".bash", ".css", ".scss", ".html", ".proto", ".graphql", ".gql", ".xml", ".conf", ".ini", ".rs", ".py", ".c", ".h", ".cpp", ".hpp", ".vue", ".properties", ".cfg", ".tf", ".hcl", ".tpl":
		return true
	}
	return false
}

func generated(data []byte) bool {
	header := strings.ToLower(string(data[:min(len(data), 512)]))
	return strings.Contains(header, "code generated") && strings.Contains(header, "do not edit")
}
