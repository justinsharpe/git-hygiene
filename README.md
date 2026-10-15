# git-hygiene

A config-driven set of POSIX-sh git hooks that keep commits clean: a
bulk-stage guard, secret scanning, and a forbidden-file policy, plus an
optional no-stash guard.

## Why this exists

In September 2026 a `git commit` accidentally swept in 8,921 pre-staged files —
build artifacts another process had left staged — and landed them on `main`.
It was caught and reverted the same day, but the cleanup cost was real (thousands
of blobs, hundreds of MB of history). Around the same time, a `git stash pop`
wrote merge-conflict markers into a tracked runtime file, and the corruption was
auto-committed for days before anyone noticed.

These hooks exist so neither failure class can recur. The bulk-stage guard makes
an accidental mega-commit mechanically impossible; the no-stash guard makes
stashing into a shared tree impossible at the engine level; the secret and
forbidden-file policies make it cheap to keep secrets and junk out of history in
the first place.

## What the hook enforces

`pre-commit` blocks a commit when any of these fire:

1. **Bulk-stage guard** — two rules in one:
   - **Count cap** — more than `GIT_HYGIENE_BULK_CAP` staged files (default 100)
     is rejected unless `GIT_HYGIENE_BULK_OK=1` is set.
   - **Artifact-shape rule** — staging a `DerivedData/`, `node_modules/`,
     `.build/`, `build/Debug|Release/`, or `.xcresult/` path is blocked
     **regardless of count**. Build artifacts never belong in history.
2. **Secret scan** — two layers:
   - **gitleaks** (optional) runs its full ruleset over the staged content in a
     temp tree. If gitleaks is not installed, the scan is skipped cleanly and the
     skip is recorded to the log — the other checks still run.
   - **Legacy pattern scan** (always runs) for `sk-` / `ghp_` / `gho_` / `AIza`
     token shapes, kept as belt-and-braces because gitleaks' default ruleset
     misses some of those classes.
3. **Forbidden-file policy** — no `.env` files, `backups/`, or `.zip` archives
   (pattern is configurable).

`reference-transaction` (no-stash guard) refuses `refs/stash` creation, which
makes `git stash push/store/create` fail before the worktree is touched. Stash
deletes (`drop`, pop cleanup) are allowed.

`global-pre-commit` (for `core.hooksPath`) adds three machine-wide layers:
an optional author-identity law, an advisory that warns when `AGENTS.md` is
edited inside a linked worktree, and delegation to any repo-local gate.

## Install

**Per-repo** (copy the hook in):

    install -m 755 pre-commit .git/hooks/pre-commit
    install -m 755 reference-transaction .git/hooks/reference-transaction

**Machine-wide** (all repos via `core.hooksPath`):

    mkdir -p ~/.git-hooks
    install -m 755 pre-commit ~/.git-hooks/pre-commit
    install -m 755 global-pre-commit ~/.git-hooks/pre-commit   # optional, machine-wide layers
    git config --global core.hooksPath ~/.git-hooks

Edit the canonical files in this repo, then re-run the install command — never
edit the installed copy in `.git/hooks/` directly (it is untracked).

## Configuration

Precedence, highest first: **environment variables** → a **`.git-hygiene` file
at the repo root** (a POSIX shell snippet of `KEY=value` lines) → **built-in
defaults**.

| Variable | Default | Purpose |
| --- | --- | --- |
| `GIT_HYGIENE_BULK_CAP` | `100` | Max staged files before the bulk guard trips. |
| `GIT_HYGIENE_BULK_OK` | `0` | `1` = exempt the bulk cap and artifact rule (secret scan still applies). |
| `GIT_HYGIENE_LOG` | `<repo>/.git/git-hygiene.log` | Log path for scan skips and gitleaks errors. Set empty to disable. |
| `GIT_HYGIENE_GITLEAKS_MAX_BYTES` | `52428800` (50 MiB) | Blobs larger than this are skipped by the gitleaks scan (hash-pinned by git). |
| `GIT_HYGIENE_SECRET_EXCLUDE` | *(empty)* | Whitespace-separated paths/globs to exclude from the legacy pattern scan. |
| `GIT_HYGIENE_FORBIDDEN_PATTERN` | `\.env$\|backups/\|.*\.zip$` | Extended regex of paths that must never be staged. |
| `GIT_HYGIENE_ARTIFACT_PATTERN` | *(see below)* | Extended regex of build-artifact paths blocked by the artifact rule. |
| `GIT_HYGIENE_CTX_CHECK` | *(empty)* | Path to an optional context-cap checker, run when `AGENTS.md` is staged. |
| `GIT_HYGIENE_STASH_OK` | `0` | `1` = allow `git stash` (escape hatch for the no-stash guard). |
| `GIT_HYGIENE_STASH_LOG` | `<repo>/.git/stash-block.log` | Log path for blocked stash attempts. |
| `GIT_HYGIENE_AUTHOR_NAME` / `_EMAIL` | *(empty)* | When both set, the global hook enforces this exact author identity. |
| `GIT_HYGIENE_MASTER_LAW` | `1` | `0` = disable the worktree `AGENTS.md` advisory. |
| `GIT_HYGIENE_REPO_GATE` | `tools/git-hygiene/pre-commit` | Repo-relative path the global hook delegates to. |

Default artifact pattern:

    (^|/)(DerivedData|node_modules|\.build|build/Debug|build/Release|\.xcresult)/

## gitleaks (optional)

gitleaks is **not** required. When `gitleaks` is on your `PATH`, staged content is
scanned with its full ruleset, honouring a repo-root `.gitleaks.toml` if one
exists. When it is absent, the hook records the skip to `GIT_HYGIENE_LOG` and
continues — the legacy pattern scan still runs, and no other check is dropped.

    # install gitleaks (macOS / Homebrew)
    brew install gitleaks

## Self-test

    ./hooktest.sh

Creates a throwaway repo in your temp dir, stages files that *should* be blocked
(bulk cap, artifacts, secrets, `.env`), runs the real hook, and asserts each block
via exit code. Prints a pass/fail line and exits non-zero on any failure.

## License

MIT — see [LICENSE](LICENSE).
