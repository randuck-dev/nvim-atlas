#!/usr/bin/env bash

# Stress test: the sidebar against a big, busy setup like a work machine.
# One repo with many worktrees, live Claude sessions (some working),
# conversations on disk for every worktree, PRs, tmux panes, and
# "Claude" running `git add` in a few worktrees the whole time. Runs the
# sidebar headless with its normal polling, then prints where time and
# CPU went (:AtlasStats) plus totals measured from outside.
#
# Everything is isolated in a temp folder: its own HOME, claude-status
# folder and tmux server, a fake `gh` and a fake `claude` process. Your
# real sessions, sections and tmux are never touched. Needs the real
# claude-status/git-review (ATLAS_STRESS_BIN_DIR, default
# ~/.dotfiles/bin), jq, git and tmux.
#
# Knobs (environment):
#   ATLAS_STRESS_SECONDS    how long to run          (60)
#   ATLAS_STRESS_WORKTREES  worktrees in the repo    (40)
#   ATLAS_STRESS_LIVE       live Claude sessions     (12)
#   ATLAS_STRESS_CHATS      conversations/worktree   (5)
#   ATLAS_STRESS_FILES      files in the repo        (2000)
#   ATLAS_STRESS_WRITERS    worktrees where "Claude" runs git add (3)
#   ATLAS_STRESS_PLUGIN     plugin checkout to test  (this one), e.g. an
#                           older checkout to compare before/after

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

seconds=${ATLAS_STRESS_SECONDS:-60}
n_wt=${ATLAS_STRESS_WORKTREES:-40}
n_live=${ATLAS_STRESS_LIVE:-12}
n_chats=${ATLAS_STRESS_CHATS:-5}
n_files=${ATLAS_STRESS_FILES:-2000}
n_writers=${ATLAS_STRESS_WRITERS:-3}
plugin=$(cd "${ATLAS_STRESS_PLUGIN:-.}" && pwd)
bin_dir=${ATLAS_STRESS_BIN_DIR:-$HOME/.dotfiles/bin}
driver=$PWD/scripts/stress.lua

if [[ ! -x $bin_dir/claude-status || ! -x $bin_dir/git-review ]]; then
  echo "stress: needs claude-status and git-review in $bin_dir (set ATLAS_STRESS_BIN_DIR)" >&2
  exit 1
fi
((n_live <= n_wt)) || { echo "stress: ATLAS_STRESS_LIVE must be <= ATLAS_STRESS_WORKTREES" >&2; exit 1; }

# Short path on purpose: tmux socket paths are capped at ~104 chars.
# pwd -P: git reports real paths (/private/tmp on macOS), and so must we.
tmp=$(cd "$(mktemp -d /tmp/atlas-stress.XXXXXX)" && pwd -P)
sock=$tmp/tmux-$(id -u)/default
writer_pids=()
cleanup() {
  for p in "${writer_pids[@]}"; do kill "$p" 2>/dev/null || true; done
  [[ -S $sock ]] && tmux -S "$sock" kill-server 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT

# Build the fixture without the user's git config (hooks, signing).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=stress GIT_AUTHOR_EMAIL=stress@example.com
export GIT_COMMITTER_NAME=stress GIT_COMMITTER_EMAIL=stress@example.com
home=$tmp/home
projects=$home/.claude/projects
status=$tmp/status
mkdir -p "$tmp/bin" "$home" "$projects" "$status/touched"
mkdir -m 700 "$(dirname "$sock")"

echo "stress: building $n_wt worktrees of a $n_files-file repo in $tmp ..." >&2
git init -q -b main "$tmp/seed"
for ((i = 0; i < n_files; i++)); do
  d=$tmp/seed/src/m$((i % 50))
  [[ -d $d ]] || mkdir -p "$d"
  printf 'file %d\nline two\n' "$i" >"$d/f$i.txt"
done
git -C "$tmp/seed" add -A && git -C "$tmp/seed" commit -qm init
git clone -q --no-local --bare "$tmp/seed" "$tmp/origin.git"
repo=$tmp/big
git clone -q --no-local "$tmp/origin.git" "$repo"
# A GitHub origin, so PR status is looked up (through the fake gh).
git -C "$repo" remote set-url origin https://github.com/acme/big.git

wts=()
for ((i = 1; i <= n_wt; i++)); do
  b=$(printf 'wt%02d' "$i")
  wt=$repo.$b
  git -C "$repo" worktree add -q -b "$b" "$wt"
  wts+=("$wt")
  if ((i % 3 == 0)); then
    echo "work $i" >"$wt/new$i.txt" && git -C "$wt" add -A && git -C "$wt" commit -qm "work $i"
  fi
  if ((i % 4 == 0)); then
    echo "uncommitted" >>"$wt/src/m0/f0.txt"
  fi
done

# Settle the worktrees like ones that have been used: a normal git
# status once, a second after checkout, writes an index whose entries
# aren't "racily clean". Otherwise every lock-free status (see
# atlas.perf) re-reads all files, which real worktrees don't do.
sleep 1
for wt in "${wts[@]}"; do git -C "$wt" status --porcelain >/dev/null; done

# Fake gh: a PR for every worktree branch, after a network-ish delay.
{
  echo "["
  for ((i = 1; i <= n_wt; i++)); do
    ((i > 1)) && echo ","
    case $((i % 4)) in 0) st=MERGED ;; 1) st=OPEN ;; 2) st=OPEN ;; 3) st=CLOSED ;; esac
    printf '{"number":%d,"state":"%s","url":"https://github.com/acme/big/pull/%d","headRefName":"wt%02d","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","statusCheckRollup":[{"conclusion":"SUCCESS"},{"conclusion":""}]}' "$i" "$st" "$i" "$i"
  done
  echo "]"
} >"$tmp/prs.json"
printf '#!/bin/sh\nsleep 0.3\ncat %q\n' "$tmp/prs.json" >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

# Fake Claude: a process named "claude", so the sidebar's tmux pane
# detection sees it. macOS names a process after its binary (a symlink
# to sleep works; a copy is killed for its code signature); Linux names
# a script after itself (a symlink would break coreutils' multi-call
# sleep).
if [[ $(uname) == Darwin ]]; then
  ln -s /bin/sleep "$tmp/bin/claude"
else
  printf '#!/bin/sh\nsleep "$@"\n' >"$tmp/bin/claude"
  chmod +x "$tmp/bin/claude"
fi

# Claude's folder name for a path: every non-alphanumeric char as "-".
enc() { printf '%s' "${1//[^a-zA-Z0-9-]/-}"; }

# Conversations on disk for every worktree (unresumed sessions), plus
# folders whose worktree is gone, like a long-used ~/.claude/projects.
pad=$(printf '%0400d' 0)
for ((i = 0; i < n_wt; i++)); do
  wt=${wts[$i]}
  d=$projects/$(enc "$wt")
  mkdir -p "$d"
  for ((c = 0; c < n_chats; c++)); do
    f=$d/chat-$i-$c.jsonl
    printf '{"type":"user","cwd":"%s","sessionId":"chat-%d-%d"}\n' "$wt" "$i" "$c" >"$f"
    for ((l = 0; l < 30; l++)); do printf '{"type":"assistant","text":"%s"}\n' "$pad" >>"$f"; done
    printf '{"type":"ai-title","aiTitle":"Conversation %d in wt %d"}\n' "$c" "$i" >>"$f"
  done
done
for ((i = 0; i < 60; i++)); do
  d=$projects/-gone-$i
  mkdir -p "$d"
  printf '{"type":"user","cwd":"/gone/%d"}\n' "$i" >"$d/old-$i.jsonl"
done

# Isolated tmux server: a window per live session running fake Claude,
# plus two Claude panes claude-status doesn't know about.
tmux -S "$sock" new-session -d -s claude -x 200 -y 50 "sleep 99999"
now=$(date +%s)
states=(working input done working)
for ((i = 0; i < n_live; i++)); do
  wt=${wts[$i]}
  pane=$(tmux -S "$sock" new-window -P -F '#{pane_id}' -t claude: -c "$wt" "$tmp/bin/claude 99999")
  pid=$(tmux -S "$sock" display -p -t "$pane" '#{pane_pid}')
  sid=live-$i
  printf '{"state":"%s","cwd":"%s","tmux_pane":"%s","session_id":"%s","pid":%d,"updated":%d,"since":%d,"transcript":"%s","title":"Live session %d","detail":"","last_prompt":"do the thing"}\n' \
    "${states[$((i % 4))]}" "$wt" "$pane" "$sid" "$pid" "$now" "$((now - 60 * i))" "$projects/$(enc "$wt")/chat-$i-0.jsonl" "$i" >"$status/$sid"
done
for ((i = n_live; i < n_live + 2 && i < n_wt; i++)); do
  tmux -S "$sock" new-window -t claude: -c "${wts[$i]}" "$tmp/bin/claude 99999"
done
# Touched worktrees: every session (live or ended) touched its own
# worktree and the next one.
for ((i = 0; i < n_wt; i++)); do
  sid=$([[ $i -lt $n_live ]] && echo "live-$i" || echo "ended-$i")
  next=${wts[$(((i + 1) % n_wt))]}
  printf '{"session_id":"%s","cwd":"%s","title":"Session %d","transcript":"","updated":%d,"paths":{"%s":%d,"%s":%d}}\n' \
    "$sid" "${wts[$i]}" "$i" "$now" "${wts[$i]}" "$now" "$next" "$now" >"$status/touched/$sid"
done

# "Claude" working: git add in a loop in the first few worktrees,
# counting attempts and failures on .git/index.lock. Runs without
# GIT_OPTIONAL_LOCKS, like Claude would.
for ((i = 0; i < n_writers && i < n_wt; i++)); do
  (
    wt=${wts[$i]}
    while :; do
      echo "$RANDOM" >>"$wt/claude-edit.txt"
      if ! out=$(git -C "$wt" add claude-edit.txt 2>&1); then
        [[ $out == *index.lock* ]] && echo x >>"$tmp/lock-failures"
      fi
      echo x >>"$tmp/git-adds"
      sleep 0.05
    done
  ) &
  writer_pids+=($!)
done

echo "stress: running the sidebar for ${seconds}s ($n_wt worktrees, $n_live live sessions, $n_writers writers) ..." >&2
TIMEFORMAT='%R %U %S'
times=$({ time env -u TMUX -u TMUX_PANE \
  HOME="$home" PATH="$tmp/bin:$PATH" TMUX_TMPDIR="$tmp" CLAUDE_STATUS_DIR="$status" \
  ATLAS_STRESS_PLUGIN="$plugin" ATLAS_STRESS_BIN_DIR="$bin_dir" ATLAS_STRESS_SECONDS="$seconds" \
  nvim --headless --clean -l "$driver" >"$tmp/report.txt" 2>"$tmp/nvim-stderr.txt"; } 2>&1)
read -r real user sys <<<"$times"

for p in "${writer_pids[@]}"; do kill "$p" 2>/dev/null || true; done
writer_pids=()
cat "$tmp/report.txt"
if [[ -s $tmp/nvim-stderr.txt ]]; then
  echo
  echo "Neovim stderr (first lines):"
  head -5 "$tmp/nvim-stderr.txt" | sed 's/^/  /'
fi
adds=$(wc -l <"$tmp/git-adds" 2>/dev/null | tr -d ' ' || echo 0)
locks=$( (wc -l <"$tmp/lock-failures") 2>/dev/null | tr -d ' ' || echo 0)
echo
echo "Measured from outside:"
awk -v r="$real" -v u="$user" -v s="$sys" 'BEGIN {
  printf "  Neovim + everything it started: %.1fs CPU in %.1fs = %.0f%% of one core\n", u + s, r, 100 * (u + s) / r }'
echo "  simulated Claude git add: $adds runs, ${locks:-0} failed on .git/index.lock"
