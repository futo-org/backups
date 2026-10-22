# Columbo

Columbo investigates support tickets using account-scoped telemetry and read-only repository tools. Results go to the paired staff thread.

## Embedded repository

`mise columbo:build` and the container build generate a bare Git repository containing committed build HEAD, release tags, and their reachable history, then compile its files into the binary using `go:embed`. No ZIP, external repository volume, runtime Git executable, checkout, or shell is required. Git's native object encoding and packfiles remain intact so `go-git` can inspect exact versions and arbitrary embedded commit hashes.

The build excludes local Git configuration, credentials, hooks, remotes, working-tree changes, and unreachable objects. Source tools exclude secrets such as `.env` paths, dependencies, generated clients, fixtures, tests, binaries, symlinks, and oversized files. Excluded content is unavailable through the tools even if present in Git history.

The build refuses to publish a repository containing secret-bearing paths in any committed tree, including files deleted before HEAD. The path guard covers private environment files, private keys, credential files, and credential/secret directories; deliberate `.env.example`, `.env.sample`, `.env.template` files and Helm secret templates are allowed. It inspects paths, not secret values. Original Git objects and commit hashes are preserved; runtime source filters do not remove objects from the embedded history.

The tools list releases and files, read line ranges, perform bounded literal searches, compare a file between exact revisions, and read first-parent history. A read-only adapter bridges `embed.FS` into `go-git`; object hashes and decoded size limits are verified while loading an isolated in-memory repository. The in-memory store supports Git mutations internally without changing the embedded packfiles; LLM tools expose only read operations. Missing versions are reported as unavailable, with no substitution of HEAD. The release index shows at most 128 tags; full embedded commit hashes remain readable outside that index. Search results and file excerpts carry revision and line evidence.

Decoded Git objects are capped at 128 MiB, with a 4 MiB temporary decode cache. The image defaults to `GOMEMLIMIT=160MiB` to leave headroom within the chart’s 256 MiB container limit.

Direct `go build` uses the last generated repository, or reports source unavailable if none exists. To refresh it manually from the repository root:

```sh
cd packages/columbo
go run ./cmd/embed-repository -repo ../..
go build -o ../../dist/columbo .
```
