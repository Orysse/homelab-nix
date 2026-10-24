#!/usr/bin/env bash
# Tests for job-triage, run by checks.<system>.job-triage.
# On PATH: job-triage, agent-status, jq, coreutils, grep, bash. claude and curl are stubs at the
# front of PATH. A stub reads $HOME/stub-exit (exit status, default 0). The curl stub prints
# $HOME/pulls.json and records its arguments and stdin; the claude stub records its arguments and
# stdin, and prints a report. PRESSURE_FILE replaces /proc/pressure/memory.
set -u

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok: $*"; }
check_eq() { # NAME GOT WANT
  if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}
check_has() { # NAME TEXT PATTERN (grep -E)
  if grep -qE -- "$3" <<<"$2"; then ok "$1"; else fail "$1: no match for '$3' in: $2"; fi
}
check_lacks() { # NAME TEXT PATTERN (grep -E)
  if grep -qE -- "$3" <<<"$2"; then fail "$1: found '$3' in: $2"; else ok "$1"; fi
}

tmp=$(mktemp -d)
export HOME=$tmp/home
export AGENT_STATUS_DIR=$tmp/agents
export XDG_RUNTIME_DIR=$tmp/run
export PRESSURE_FILE=$tmp/pressure
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
trap 'rm -rf "$tmp"' EXIT
unset GITHUB_TOKEN

# The sandbox has no /usr/bin/env: the stubs get the absolute path of bash as interpreter.
sh=$(command -v bash)
stubs=$tmp/stubs
mkdir -p "$stubs"
cat >"$stubs/claude" <<EOF
#!$sh
echo called >>"\$HOME/claude-calls"
printf '%s\n' "\$@" >"\$HOME/claude-args"
printf '%s\n' "token=\${GITHUB_TOKEN-unset}" "hook-disable=\${AGENT_HOOK_DISABLE-unset}" >"\$HOME/claude-env"
cat >"\$HOME/claude-stdin"
[[ -r \$HOME/stub-exit ]] && exit "\$(<"\$HOME/stub-exit")"
echo "# Renovate triage"
echo "stub report"
exit 0
EOF
cat >"$stubs/curl" <<EOF
#!$sh
echo called >>"\$HOME/curl-calls"
printf '%s\n' "\$@" >"\$HOME/curl-args"
cat >"\$HOME/curl-stdin"
[[ -r \$HOME/curl-exit ]] && exit "\$(<"\$HOME/curl-exit")"
cat "\$HOME/pulls.json"
EOF
chmod +x "$stubs"/*
export PATH=$stubs:$PATH

# Two open PRs: one from Renovate, one from a person.
cat >"$HOME/pulls.json" <<'EOF'
[
  {"number": 41, "title": "chore(deps): update flake.lock", "html_url": "https://github.com/Orysse/homelab-nix/pull/41",
   "created_at": "2026-10-20T04:00:00Z", "draft": false, "user": {"login": "renovate[bot]"},
   "head": {"ref": "renovate/flake-lock"}, "labels": [{"name": "dependencies"}], "body": "Bumps nixpkgs."},
  {"number": 42, "title": "docs: typo", "html_url": "https://github.com/Orysse/homelab-nix/pull/42",
   "created_at": "2026-10-21T04:00:00Z", "draft": false, "user": {"login": "someone"},
   "head": {"ref": "typo"}, "labels": [], "body": "typo"}
]
EOF

field() { jq -r ".$1" "$AGENT_STATUS_DIR/job-triage.json" 2>/dev/null; }
reset() { rm -rf "$HOME/claude-env" "$HOME/pwned" "$tmp/pwned" "$HOME/claude-calls" "$HOME/claude-args" "$HOME/claude-stdin" "$HOME/curl-calls" "$HOME/curl-args" "$HOME/curl-stdin" "$HOME/stub-exit" "$HOME/curl-exit" "$HOME/reports" "$AGENT_STATUS_DIR" "$XDG_RUNTIME_DIR/devbox-env"; }
today=$(date +%F)

# --- high memory pressure: skipped, nothing called
reset
echo 'some avg10=25.00 avg60=3.00 avg300=1.00 total=123' >"$PRESSURE_FILE"
echo 'full avg10=0.00 avg60=0.00 avg300=0.00 total=0' >>"$PRESSURE_FILE"
GITHUB_TOKEN=t job-triage; rc=$?
check_eq "pressure 25.00: exit status" "$rc" "0"
check_eq "pressure 25.00: state skipped" "$(field state)" "skipped"
check_has "pressure 25.00: the task says why" "$(field task)" 'pressure'
check_eq "pressure 25.00: claude not called" "$(cat "$HOME/claude-calls" 2>/dev/null)" ""
check_eq "pressure 25.00: curl not called" "$(cat "$HOME/curl-calls" 2>/dev/null)" ""
check_eq "row id" "$(field id)" "job-triage"
check_eq "row agent" "$(field agent)" "claude"
check_eq "row machine is this host" "$(field machine)" "$(<"/proc/sys/kernel/hostname")"

# --- the threshold is 20.00 included, and only the `some` line counts
reset
printf 'some avg10=20.00 avg60=0.00 avg300=0.00 total=1\n' >"$PRESSURE_FILE"
GITHUB_TOKEN=t job-triage
check_eq "pressure 20.00 is skipped" "$(field state)" "skipped"
reset
printf 'some avg10=19.99 avg60=90.00 avg300=90.00 total=1\nfull avg10=50.00 avg60=0.00 avg300=0.00 total=1\n' >"$PRESSURE_FILE"
GITHUB_TOKEN=t job-triage
check_eq "pressure 19.99 (other fields high) runs" "$(field state)" "done"

# --- low pressure: done, report file, restricted claude
reset
echo 'some avg10=1.00 avg60=0.00 avg300=0.00 total=1' >"$PRESSURE_FILE"
GITHUB_TOKEN=secret-token-123 job-triage; rc=$?
check_eq "pressure 1.00: exit status" "$rc" "0"
check_eq "pressure 1.00: state done" "$(field state)" "done"
report=$HOME/reports/triage-$today.md
[[ -f $report ]] && ok "report file exists" || fail "no report at $report"
check_has "report has the claude output" "$(cat "$report" 2>/dev/null)" 'stub report'
check_eq "reports dir is private" "$(stat -c %a "$HOME/reports")" "700"
check_has "done task names the report" "$(field task)" "triage-$today.md"
check_eq "row log is the report" "$(field log)" "$report"
check_eq "claude called once" "$(wc -l <"$HOME/claude-calls")" "1"
args=$(cat "$HOME/claude-args")
check_has "claude runs headless (-p)" "$args" '^-p$'
mapfile -t argv <"$HOME/claude-args"
tools_at=-1
for i in "${!argv[@]}"; do [[ ${argv[$i]} == --tools ]] && tools_at=$i; done
if ((tools_at >= 0)); then
  check_eq "claude has no tools (--tools '')" "${argv[tools_at + 1]-unset}" ""
else
  fail "claude is not given --tools"
fi
check_has "claude never asks for permission" "$args" '^--permission-prompts$'
check_has "claude does not keep a session" "$args" '^--no-session-persistence$'
check_lacks "claude is not given dangerous flags" "$args" 'dangerously|bypassPermissions|acceptEdits|allowedTools|--mcp-config'
check_has "claude takes no MCP server (--strict-mcp-config)" "$args" '^--strict-mcp-config$'
sources_at=-1
for i in "${!argv[@]}"; do [[ ${argv[$i]} == --setting-sources ]] && sources_at=$i; done
if ((sources_at >= 0)); then
  check_eq "claude loads no settings source (--setting-sources '')" "${argv[sources_at + 1]-unset}" ""
else
  fail "claude is not given --setting-sources"
fi
check_eq "claude does not inherit the token" "$(sed -n 1p "$HOME/claude-env")" "token=unset"
check_eq "claude runs with the agent hook disabled" "$(sed -n 2p "$HOME/claude-env")" "hook-disable=1"
check_has "the prompt says read-only" "$args" 'read-only|Do not'
check_has "claude gets the Renovate PR" "$(cat "$HOME/claude-stdin")" '"number": ?41'
check_lacks "claude does not get other PRs" "$(cat "$HOME/claude-stdin")" '"number": ?42'
check_lacks "the token is not in claude's arguments" "$args" 'secret-token-123'
check_lacks "the token is not in curl's arguments" "$(cat "$HOME/curl-args")" 'secret-token-123'
check_has "the token reaches curl on stdin" "$(cat "$HOME/curl-stdin")" 'secret-token-123'
check_has "curl asks for the repository" "$(cat "$HOME/curl-args")" 'Orysse/homelab-nix/pulls'

# --- the credential comes from $XDG_RUNTIME_DIR/devbox-env when the environment has none
envfile=$XDG_RUNTIME_DIR/devbox-env
# write_env MODE TEXT: a devbox-env file of this mode
write_env() { rm -f "$envfile"; (umask 0; printf '%s' "$2" >"$envfile"); chmod "$1" "$envfile"; }

reset
write_env 600 $'OTHER=1\nGITHUB_TOKEN=from-env-file\nBAO_ADDR=x\n'
job-triage
check_eq "token from devbox-env: done" "$(field state)" "done"
check_has "token from devbox-env reaches curl" "$(cat "$HOME/curl-stdin")" 'from-env-file'
check_eq "token from devbox-env: not inherited by claude" "$(sed -n 1p "$HOME/claude-env")" "token=unset"

# the first GITHUB_TOKEN= line wins, the value is what follows the first =
reset
write_env 600 $'GITHUB_TOKEN=first.token_1\nGITHUB_TOKEN=second\n'
job-triage
check_has "first GITHUB_TOKEN line is used" "$(cat "$HOME/curl-stdin")" 'first.token_1'
check_lacks "second GITHUB_TOKEN line is ignored" "$(cat "$HOME/curl-stdin")" 'second'

# the environment wins over the file
reset
write_env 600 $'GITHUB_TOKEN=from-file\n'
GITHUB_TOKEN=from-env job-triage
check_has "environment token wins" "$(cat "$HOME/curl-stdin")" 'from-env'
check_lacks "environment token wins over the file" "$(cat "$HOME/curl-stdin")" 'from-file'

# hostile file: nothing is executed, other variables are not imported, the row is updated
hostile() { # NAME TEXT WANT_TASK_PATTERN
  reset
  write_env 600 "$2"
  PATH_BEFORE=$PATH
  job-triage; rc=$?
  check_eq "hostile $1: exit status" "$rc" "0"
  check_eq "hostile $1: state failed" "$(field state)" "failed"
  check_has "hostile $1: task" "$(field task)" "$3"
  [[ ! -e $HOME/pwned && ! -e $tmp/pwned && ! -e ./pwned ]] && ok "hostile $1: nothing executed" || fail "hostile $1: a command ran"
  check_eq "hostile $1: claude not called" "$(cat "$HOME/claude-calls" 2>/dev/null)" ""
  check_eq "hostile $1: curl not called" "$(cat "$HOME/curl-calls" 2>/dev/null)" ""
  check_eq "hostile $1: PATH untouched" "$PATH" "$PATH_BEFORE"
}
hostile command-substitution "GITHUB_TOKEN=\$(touch $HOME/pwned)"$'\n' 'unexpected shape'
hostile backticks "GITHUB_TOKEN=\`touch $HOME/pwned\`"$'\n' 'unexpected shape'
hostile spaces $'GITHUB_TOKEN=abc def\n' 'unexpected shape'
hostile semicolon "GITHUB_TOKEN=abc;touch $HOME/pwned"$'\n' 'unexpected shape'
hostile quotes $'GITHUB_TOKEN="abc"\n' 'unexpected shape'
hostile export-prefix $'export GITHUB_TOKEN=abc\n' '^no GitHub credential$'
hostile other-variables-only "PATH=$tmp/stubs:/nonexistent"$'\n'"LD_PRELOAD=/x"$'\n' '^no GitHub credential$'
hostile first-line-bad "GITHUB_TOKEN=\$(touch $HOME/pwned)"$'\nGITHUB_TOKEN=good\n' 'unexpected shape'
hostile empty-file '' '^no GitHub credential$'

# wrong mode, wrong kind of file, missing file: the credential is absent
for mode in 640 604 660 666 644 400; do
  reset
  write_env "$mode" $'GITHUB_TOKEN=valid-token\n'
  job-triage
  if [[ $mode == 400 ]]; then
    check_eq "devbox-env mode $mode is accepted" "$(field state)" "done"
  else
    check_eq "devbox-env mode $mode: state failed" "$(field state)" "failed"
    check_eq "devbox-env mode $mode: task" "$(field task)" "no GitHub credential"
    check_eq "devbox-env mode $mode: curl not called" "$(cat "$HOME/curl-calls" 2>/dev/null)" ""
  fi
done
reset
rm -f "$envfile"
job-triage
check_eq "devbox-env missing: state failed" "$(field state)" "failed"
check_eq "devbox-env missing: task" "$(field task)" "no GitHub credential"
reset
write_env 600 $'GITHUB_TOKEN=valid-token\n'
mv "$envfile" "$tmp/real-env"
ln -s "$tmp/real-env" "$envfile"
job-triage
check_eq "devbox-env symlink: state failed" "$(field state)" "failed"
check_eq "devbox-env symlink: task" "$(field task)" "no GitHub credential"
reset
mkdir "$envfile"
job-triage
check_eq "devbox-env directory: state failed" "$(field state)" "failed"
check_eq "devbox-env directory: task" "$(field task)" "no GitHub credential"
rmdir "$envfile"

# --- no open Renovate PR: a report, no claude call
reset
echo '[]' >"$HOME/pulls.json.empty"
cp "$HOME/pulls.json" "$HOME/pulls.json.full"
cp "$HOME/pulls.json.empty" "$HOME/pulls.json"
GITHUB_TOKEN=t job-triage
check_eq "no PR: done" "$(field state)" "done"
check_eq "no PR: claude not called" "$(cat "$HOME/claude-calls" 2>/dev/null)" ""
check_has "no PR: the report says so" "$(cat "$report" 2>/dev/null)" 'No open Renovate'
cp "$HOME/pulls.json.full" "$HOME/pulls.json"

# --- claude fails
reset
echo 3 >"$HOME/stub-exit"
GITHUB_TOKEN=t job-triage; rc=$?
check_eq "claude fails: exit status" "$rc" "0"
check_eq "claude fails: state failed" "$(field state)" "failed"
[[ ! -e $report ]] && ok "claude fails: no report left" || fail "report exists after a failure"

# --- GitHub fails
reset
echo 22 >"$HOME/curl-exit"
GITHUB_TOKEN=t job-triage; rc=$?
check_eq "curl fails: exit status" "$rc" "0"
check_eq "curl fails: state failed" "$(field state)" "failed"
check_eq "curl fails: claude not called" "$(cat "$HOME/claude-calls" 2>/dev/null)" ""

# --- no credential
reset
job-triage; rc=$?
check_eq "no credential: exit status" "$rc" "0"
check_eq "no credential: state failed" "$(field state)" "failed"
check_eq "no credential: task" "$(field task)" "no GitHub credential"
check_eq "no credential: claude not called" "$(cat "$HOME/claude-calls" 2>/dev/null)" ""
check_eq "no credential: curl not called" "$(cat "$HOME/curl-calls" 2>/dev/null)" ""

# --- the working row has the pid of the job (reconcile can track it)
reset
cat >"$stubs/claude" <<EOF
#!$sh
jq -r '.pid' "\$AGENT_STATUS_DIR/job-triage.json" >"\$HOME/seen-pid"
jq -r '.state' "\$AGENT_STATUS_DIR/job-triage.json" >"\$HOME/seen-state"
cat >/dev/null
echo report
EOF
GITHUB_TOKEN=t job-triage
check_eq "row is working while claude runs" "$(cat "$HOME/seen-state")" "working"
check_has "working row has a pid" "$(cat "$HOME/seen-pid")" '^[0-9]+$'

if ((fails > 0)); then
  echo "$fails check(s) failed" >&2
  exit 1
fi
echo "all job checks passed"
