#!/bin/sh
# git-hygiene — self-test.
#
# Creates a THROWAWAY repo, stages files that SHOULD be blocked, runs the real
# hook, and asserts the block via exit code. Exits 0 iff every case behaves as
# expected. Run:
#
#     ./hooktest.sh
#
# Requires git and (optionally) gitleaks; the secret-scan cases are caught by the
# built-in pattern scan even when gitleaks is absent.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/pre-commit"
[ -r "$HOOK" ] || { echo "FATAL: $HOOK not found"; exit 2; }

T="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/git-hygiene-hooktest.$$")"
rm -rf "$T"; mkdir -p "$T" && cd "$T" || exit 2

git init -q .
git config user.email "hooktest@example.invalid"
git config user.name "hook-test"
# Isolate from any ambient global core.hooksPath (e.g. a machine-wide hook) so
# the test exercises THIS repo's installed hook and nothing else.
git config core.hooksPath "$T/.git/hooks"

# Keep the hook's log inside the throwaway repo so the test leaves no trace.
export GIT_HYGIENE_LOG="$T/.git/git-hygiene.log"

cp "$HOOK" .git/hooks/pre-commit
chmod 755 .git/hooks/pre-commit

# Synthetic test tokens built at RUNTIME so this file never contains a literal
# secret-shaped string (the hook it tests would otherwise flag this very file).
GHP_TOKEN="ghp_$(printf '%s' '0123456789abcdef0123456789abcdef')"
SK_TOKEN="sk-ant-api03-$(printf '%s' '0123456789abcdef0123456789abcdef')"

pass=0; fail=0

expect_block() { # $1=label
  if git commit -q -m "t" 2>err.txt; then
    echo "FAIL (not blocked): $1"; cat err.txt; fail=$((fail+1))
  elif grep -qE 'BULK-STAGE GUARD BLOCKED|SECURITY COMMIT BLOCKED|PRE-COMMIT BLOCKED' err.txt; then
    echo "PASS (blocked):    $1"; pass=$((pass+1))
  else
    echo "FAIL (blocked, wrong reason): $1"; cat err.txt; fail=$((fail+1))
  fi
}

expect_allow() { # $1=label
  if git commit -q -m "t" 2>err.txt; then
    echo "PASS (allowed):    $1"; pass=$((pass+1))
  else
    echo "FAIL (blocked): $1"; head -3 err.txt; fail=$((fail+1))
  fi
}

# T1 — small commit passes.
echo a > a.txt; git add a.txt
expect_allow "T1 small commit"

# T2 — bulk count cap: 120 files, no exemption.
i=1; while [ "$i" -le 120 ]; do echo x > "f$i.txt"; i=$((i+1)); done
git add f*.txt
expect_block "T2 count cap (120 files)"

# T3 — same bulk, GIT_HYGIENE_BULK_OK=1 exempts the cap.
if GIT_HYGIENE_BULK_OK=1 git commit -q -m "t3" 2>err.txt; then
  echo "PASS (allowed):    T3 bulk w/ GIT_HYGIENE_BULK_OK=1"; pass=$((pass+1))
else
  echo "FAIL: T3 bulk w/ GIT_HYGIENE_BULK_OK=1"; head -3 err.txt; fail=$((fail+1))
fi

# T4 — artifact shape blocked regardless of count (no exemption).
git reset -q
mkdir -p app/DerivedData/Build
echo obj > app/DerivedData/Build/o.o
echo src > app/main.swift
git add app/DerivedData/Build/o.o app/main.swift
expect_block "T4 artifact shape (DerivedData, 2 files)"

# T5 — artifact shape with GIT_HYGIENE_BULK_OK=1 passes.
if GIT_HYGIENE_BULK_OK=1 git commit -q -m "t5" 2>err.txt; then
  echo "PASS (allowed):    T5 artifact w/ GIT_HYGIENE_BULK_OK=1"; pass=$((pass+1))
else
  echo "FAIL: T5 artifact w/ GIT_HYGIENE_BULK_OK=1"; head -3 err.txt; fail=$((fail+1))
fi

# T6 — secret pattern (ghp_ token) blocked.
git reset -q
echo "token = \"$GHP_TOKEN\"" > leak.txt
git add leak.txt
expect_block "T6 ghp_ secret"

# T7 — .env staging blocked.
git reset -q
echo 'X=1' > prod.env
git add prod.env
expect_block "T7 .env policy"

# T8 — path-limited commit under a polluted index runs the hook on the temp
# index only: the other staged file (a secret) must NOT block a path-limited
# commit of one clean file.
git reset -q
echo clean > clean.txt; git add clean.txt
echo "token = \"$SK_TOKEN\"" > staged-by-other.txt; git add staged-by-other.txt
if git commit -q -m "t8" -- clean.txt 2>err.txt; then
  echo "PASS (allowed):    T8 path-limited commit ignores other staged file"; pass=$((pass+1))
else
  echo "FAIL: T8 path-limited commit"; head -3 err.txt; fail=$((fail+1))
fi

# T9 — cap-exempted commit still hits the secret scan.
git reset -q
echo "key = \"$SK_TOKEN\"" > cp.txt
git add cp.txt
if GIT_HYGIENE_BULK_OK=1 git commit -q -m "t9" 2>err.txt; then
  echo "FAIL (allowed):    T9 exempted commit with secret slipped"; fail=$((fail+1))
else
  echo "PASS (blocked):    T9 exempted commit still secret-scanned"; pass=$((pass+1))
fi

echo ""
echo "RESULT: $pass pass, $fail fail"

if [ "$fail" -eq 0 ]; then
  rm -rf "$T"
  exit 0
else
  echo "Failed repo kept for inspection: $T"
  exit 1
fi
