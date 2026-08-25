#!/usr/bin/env bash
# Behavior tests for the generated clean-worktrees clean.sh (run against the ha
# copy — all three plugin copies are generated from the same common source).
#
# Scenario A (one scratch repo, one run):
#   1. merged worktree                     → removed, branch deleted
#   2. unmerged worktree                   → blocked, untouched
#   3. merged + STALE claude-session lock (dead pid) → unlocked, removed
#   4. merged + claude-session lock held by a RUNNING pid → skipped
#   5. merged + DELIBERATE keep-lock whose text contains "rapid N"
#      (adversarial pid-regex bait)        → skipped, NEVER unlocked
#   6. merged + claude-session lock naming pid 1 (another user's LIVE process;
#      `kill -0` would misread EPERM as dead) → skipped as RUNNING
#   7. merged + lock whose liveness cannot be inspected → skipped (fail closed)
#   8. empty orphan dirs (child + group)   → removed
#   9. non-empty orphan dir                → kept and reported
#  10. UNREADABLE orphan dir (find/rmdir fail) → kept + reported, script
#      completes (no set -e abort) and the other orphans are still processed
#  11. registered depth-1 worktree with an empty subdir → subdir untouched
#
# Scenario B (fresh repo, zero merged worktrees):
#  12. the EARLY-EXIT path also sweeps orphans ("No merged worktrees" + removal)
#
# Scenario C (fresh repo, launched FROM a linked worktree):
#  13. the sweep is anchored at the MAIN checkout (REMOVE_FROM), so orphans
#      under the main checkout's .claude/worktrees are swept even when clean.sh
#      runs inside a linked worktree (GIT_ROOT != main); a merged sibling is
#      still removed from that launch point too.
#
# gh is stubbed to fail fast so merge verification deterministically uses git
# ancestry; global/system git config is neutralized (gpgsign/hooksPath immunity).
set -euo pipefail

# Scenarios 6 (pid 1 liveness) and 9 (unreadable dir) are VACUOUS under root:
# kill -0 1 succeeds and chmod 000 is ignored (CAP_DAC_OVERRIDE). Fail loudly
# instead of silently losing their discriminating power.
[ "$(id -u)" -ne 0 ] || { echo "FAIL: must run as non-root (scenarios 6/9 are vacuous under root)" >&2; exit 1; }

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLEAN="$PLUGIN_ROOT/skills/ha-clean-worktrees/scripts/clean.sh"
TMP="${TMPDIR:-/tmp}/clean-worktrees-test.$$"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
cat > "$TMP/bin/ps" <<'SH'
#!/bin/sh
[ "${1:-}" = "-p" ] || exit 2
case "${2:-}" in
  1|"${CA_TEST_LIVE_PID:-}") exit 0;;
  "${CA_TEST_UNKNOWN_PID:-}") exit 2;;
  *) exit 1;;
esac
SH
chmod +x "$TMP/bin/ps"
export CA_TEST_LIVE_PID="$$" CA_TEST_UNKNOWN_PID=42424242
export PATH="$TMP/bin:$PATH"

fail() { echo "FAIL: $*" >&2; exit 1; }

new_repo() { # dir -> bare origin + configured clone at dir/repo
  git init -q --bare -b main "$1/origin.git"
  git clone -q "$1/origin.git" "$1/repo"
  git -C "$1/repo" config user.email t@example.invalid
  git -C "$1/repo" config user.name t
  git -C "$1/repo" commit -q --allow-empty -m init
  git -C "$1/repo" push -q origin main
}

# ============================ Scenario A =====================================
mkdir -p "$TMP/a"; new_repo "$TMP/a"; REPO="$TMP/a/repo"

make_wt() { # name branch
  mkdir -p "$REPO/.claude/worktrees/ha"
  git -C "$REPO" worktree add -q -b "$2" "$REPO/.claude/worktrees/ha/$1" main
  ( cd "$REPO/.claude/worktrees/ha/$1" \
    && echo "$1" > "$1.txt" && git add "$1.txt" \
    && git -c user.email=t@example.invalid -c user.name=t commit -qm "$1" )
}
merge_branch() { git -C "$REPO" merge -q --no-ff "$1" -m "merge $1" && git -C "$REPO" push -q origin main; }

# 1 merged / 2 unmerged
make_wt merged-plain wt/merged-plain;      merge_branch wt/merged-plain
make_wt open-branch wt/open-branch
# 3 stale claude-session lock (a pid that has provably exited)
make_wt merged-stale-lock wt/merged-stale-lock; merge_branch wt/merged-stale-lock
bash -c ':' & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null || true
export DEAD_PID
git -C "$REPO" worktree lock --reason "codex session test (pid $DEAD_PID start now)" \
  "$REPO/.claude/worktrees/ha/merged-stale-lock"
# 3b stale claude-session lock whose worktree NAME carries "(pid <live>" bait:
#    the pid group appended LAST by the lock creator must win (greedy last-match),
#    so the lock still parses the real DEAD pid and is unlocked. Pins the
#    "pid group is the final parenthesized group" property the parser relies on.
make_wt merged-bait-name wt/merged-bait-name; merge_branch wt/merged-bait-name
git -C "$REPO" worktree lock --reason "claude session bait (pid 1 x (pid $DEAD_PID start now)" \
  "$REPO/.claude/worktrees/ha/merged-bait-name"
# 4 live claude-session lock (this shell's pid)
make_wt merged-live-lock wt/merged-live-lock; merge_branch wt/merged-live-lock
git -C "$REPO" worktree lock --reason "claude session live (pid $$ start now)" \
  "$REPO/.claude/worktrees/ha/merged-live-lock"
# 5 deliberate keep-lock containing pid-regex bait ("rapid N")
make_wt merged-keep-lock wt/merged-keep-lock; merge_branch wt/merged-keep-lock
git -C "$REPO" worktree lock --reason "KEEP: rapid 4999999 files experiment, do not clean" \
  "$REPO/.claude/worktrees/ha/merged-keep-lock"
# 6 claude-session lock naming pid 1 (live, another user — kill -0 EPERM trap)
make_wt merged-eperm-lock wt/merged-eperm-lock; merge_branch wt/merged-eperm-lock
git -C "$REPO" worktree lock --reason "claude session other (pid 1 start now)" \
  "$REPO/.claude/worktrees/ha/merged-eperm-lock"
# 7 liveness inspection denied: preserve the merged, locked worktree
make_wt merged-unknown-lock wt/merged-unknown-lock; merge_branch wt/merged-unknown-lock
git -C "$REPO" worktree lock --reason "claude session restricted (pid $CA_TEST_UNKNOWN_PID start now)" \
  "$REPO/.claude/worktrees/ha/merged-unknown-lock"
# 8 empty orphans / 9 non-empty orphan
mkdir -p "$REPO/.claude/worktrees/ca" "$REPO/.claude/worktrees/sa/empty-child"
mkdir -p "$REPO/.claude/worktrees/leftover-with-content"
echo data > "$REPO/.claude/worktrees/leftover-with-content/file.txt"
# 10 unreadable non-empty orphan (find/rmdir must fail without aborting the run)
#    LOAD-BEARING fixture: it is also what discriminates the `|| true` guards on
#    the two finds — without it, deleting those guards would go undetected.
mkdir -p "$REPO/.claude/worktrees/unreadable-orphan"
echo hidden > "$REPO/.claude/worktrees/unreadable-orphan/secret.txt"
chmod 000 "$REPO/.claude/worktrees/unreadable-orphan"
# 11 registered depth-1 worktree (UNMERGED, so it stays) owning an empty subdir
git -C "$REPO" worktree add -q -b wt/depth1 "$REPO/.claude/worktrees/depth1wt" main
( cd "$REPO/.claude/worktrees/depth1wt" \
  && echo d1 > d1.txt && git add d1.txt \
  && git -c user.email=t@example.invalid -c user.name=t commit -qm d1 )
mkdir -p "$REPO/.claude/worktrees/depth1wt/emptybuilddir"

OUT="$(cd "$REPO" && bash "$CLEAN" all-merged 2>&1)" || fail "clean.sh exited non-zero: $OUT"

# 1/2 basic behavior (regression guards)
[ ! -d "$REPO/.claude/worktrees/ha/merged-plain" ] || fail "merged worktree not removed"
git -C "$REPO" show-ref --verify --quiet refs/heads/wt/merged-plain && fail "merged branch not deleted"
[ -d "$REPO/.claude/worktrees/ha/open-branch" ] || fail "unmerged worktree was removed"
git -C "$REPO" show-ref --verify --quiet refs/heads/wt/open-branch || fail "unmerged branch was deleted"
# 3 stale claude-session lock cleared
[ ! -d "$REPO/.claude/worktrees/ha/merged-stale-lock" ] || fail "stale-locked merged worktree not removed"
echo "$OUT" | grep -q "Stale session lock" || fail "stale lock path not reported"
# 3b bait in the NAME loses to the tool-appended final pid group
[ ! -d "$REPO/.claude/worktrees/ha/merged-bait-name" ] || fail "bait-named stale lock not unlocked (last-match property broken)"
echo "$OUT" | grep -q "Stale session lock (holder pid $DEAD_PID" || fail "bait-named lock did not parse the real pid"
# 4 live claude-session lock respected
[ -d "$REPO/.claude/worktrees/ha/merged-live-lock" ] || fail "live-locked worktree was removed"
echo "$OUT" | grep -q "locked by a RUNNING process (pid $$" || fail "live lock skip not reported"
# 5 deliberate keep-lock is an absolute barrier (regex bait must not parse)
[ -d "$REPO/.claude/worktrees/ha/merged-keep-lock" ] || fail "deliberately-locked worktree was removed"
echo "$OUT" | grep -q "not a recognized session lock" || fail "non-session lock skip not reported"
echo "$OUT" | grep -q "Stale session lock (holder pid 4999999" && fail "pid-regex bait was parsed from a keep-lock"
# 6 EPERM trap: pid 1 is alive even though kill -0 fails for non-root
[ -d "$REPO/.claude/worktrees/ha/merged-eperm-lock" ] || fail "worktree locked by another user's live pid was removed"
echo "$OUT" | grep -q "locked by a RUNNING process (pid 1" || fail "pid 1 not classified as running"
# 7 unknown liveness must fail closed
[ -d "$REPO/.claude/worktrees/ha/merged-unknown-lock" ] || fail "unknown-liveness lock was removed"
echo "$OUT" | grep -q "cannot verify lock-holder liveness (pid $CA_TEST_UNKNOWN_PID" || fail "unknown liveness was not reported"
# 8 empty orphans removed (child, then folded-up group; bare group too)
[ ! -d "$REPO/.claude/worktrees/ca" ] || fail "empty orphan group dir not removed"
[ ! -d "$REPO/.claude/worktrees/sa" ] || fail "emptied orphan group dir not folded up"
# 9 non-empty orphan kept and reported
[ -d "$REPO/.claude/worktrees/leftover-with-content" ] || fail "non-empty orphan was deleted"
echo "$OUT" | grep -q "ORPHANED" || fail "non-empty orphan not reported"
# 10 unreadable orphan: kept + reported; the run completed (we got here with exit 0)
[ -d "$REPO/.claude/worktrees/unreadable-orphan" ] || fail "unreadable orphan disappeared"
echo "$OUT" | grep -q "unreadable-orphan" || fail "unreadable orphan not reported"
echo "$OUT" | grep -q "=== Cleanup Complete ===" || fail "run aborted before final summary"
# 11 registered depth-1 worktree's own empty subdir untouched
[ -d "$REPO/.claude/worktrees/depth1wt/emptybuilddir" ] || fail "subdir inside a registered worktree was deleted"

# ============================ Scenario B =====================================
# Zero merged worktrees: the EARLY-EXIT path must still sweep orphans.
mkdir -p "$TMP/b"; new_repo "$TMP/b"; REPO2="$TMP/b/repo"
mkdir -p "$REPO2/.claude/worktrees/ha"          # empty orphan group dir
OUT2="$(cd "$REPO2" && bash "$CLEAN" all-merged 2>&1)" || fail "early-exit run exited non-zero: $OUT2"
echo "$OUT2" | grep -q "No merged worktrees to clean up" || fail "early-exit path not taken"
[ ! -d "$REPO2/.claude/worktrees/ha" ] || fail "early-exit path did not sweep the empty orphan"

# ============================ Scenario C =====================================
# Launched FROM a linked worktree: GIT_ROOT is the linked worktree, but the
# sweep must anchor at the MAIN checkout (REMOVE_FROM) — with a GIT_ROOT
# anchor this run finds no .claude/worktrees and silently no-ops.
mkdir -p "$TMP/c"; new_repo "$TMP/c"; REPO3="$TMP/c/repo"
git -C "$REPO3" worktree add -q -b wt/launchpoint "$REPO3/.claude/worktrees/launchpoint" main
( cd "$REPO3/.claude/worktrees/launchpoint" \
  && echo lp > lp.txt && git add lp.txt \
  && git -c user.email=t@example.invalid -c user.name=t commit -qm lp )   # unmerged: survives
git -C "$REPO3" worktree add -q -b wt/c-merged "$REPO3/.claude/worktrees/c-merged" main
( cd "$REPO3/.claude/worktrees/c-merged" \
  && echo cm > cm.txt && git add cm.txt \
  && git -c user.email=t@example.invalid -c user.name=t commit -qm cm )
git -C "$REPO3" merge -q --no-ff wt/c-merged -m "merge wt/c-merged"
git -C "$REPO3" push -q origin main
mkdir -p "$REPO3/.claude/worktrees/orphan-under-main"                     # empty orphan
OUT3="$(cd "$REPO3/.claude/worktrees/launchpoint" && bash "$CLEAN" all-merged 2>&1)" \
  || fail "linked-worktree run exited non-zero: $OUT3"
[ ! -d "$REPO3/.claude/worktrees/orphan-under-main" ] || fail "sweep missed the main checkout's orphan when launched from a linked worktree"
[ ! -d "$REPO3/.claude/worktrees/c-merged" ] || fail "merged sibling not removed when launched from a linked worktree"
[ -d "$REPO3/.claude/worktrees/launchpoint" ] || fail "unmerged launch worktree was removed"

echo "clean-worktrees-test.sh: ok"
