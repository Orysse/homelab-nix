#!/usr/bin/env bash
# Tests for agent-run, agent-hook and the Claude Code managed settings, run by checks.<system>.agent-run.
# On PATH: agent-run, agent-hook, agent-status, tmux, script, jq, coreutils, grep, bash.
# $MANAGED_SETTINGS is the generated managed-settings.json, $AGENT_HOOK_BIN the store path of agent-hook.
# tmux runs on a private socket (TMUX_TMPDIR). The agents are stubs named claude and opencode at the
# front of PATH; board is a stub that stays alive. A stub reads $HOME/stub-exit (exit status, default 0)
# and waits while $HOME/gate exists, so a test can look at the row while the agent runs.
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

tmp=$(mktemp -d)
export HOME=$tmp/home
export TMUX_TMPDIR=$tmp/tmux
export TERM=xterm
export SHELL
SHELL=$(command -v bash)
export AGENT_STATUS_DIR=$tmp/agents
# devbox-env (written by devbox-secrets) is read from here by the agent-run wrapper.
export XDG_RUNTIME_DIR=$tmp/run
unset TMUX SSH_CONNECTION AGENT_RUN_ID DEEPSEEK_API_KEY OPENROUTER_API_KEY GITHUB_TOKEN EVIL
mkdir -p "$HOME/work" "$TMUX_TMPDIR" "$tmp/elsewhere" "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
# The owner's tmux config sets base-index 1: no test may assume a window index.
echo 'set -g base-index 1' >"$HOME/.tmux.conf"
trap 'tmux kill-server 2>/dev/null; rm -rf "$tmp"' EXIT

# The sandbox has no /usr/bin/env: the stubs get the absolute path of bash as interpreter.
stubs=$tmp/stubs
mkdir -p "$stubs"
for name in claude opencode; do
  {
    echo "#!$SHELL"
    echo "echo \"stub-$name \$*\""
    echo 'echo "cwd=$PWD"'
    echo 'echo "run-id=${AGENT_RUN_ID:-}"'
    echo 'echo "keys=${DEEPSEEK_API_KEY:-}|${OPENROUTER_API_KEY:-}|${GITHUB_TOKEN:-}"'
    echo 'echo "evil=${EVIL:-}"'
    echo 'echo "stub-path=$PATH"'
    echo 'while [[ -e $HOME/gate ]]; do sleep 0.1; done'
    echo '[[ -r $HOME/stub-exit ]] && exit "$(<"$HOME/stub-exit")"'
    echo 'exit 0'
  } >"$stubs/$name"
done
{
  echo "#!$SHELL"
  echo 'exec sleep 600'
} >"$stubs/board"
chmod +x "$stubs"/*
export PATH=$stubs:$PATH

sessions() { tmux list-sessions -F '#{session_name}' 2>/dev/null | paste -sd, || true; }
windows() { tmux list-windows -t '=devbox:' -F '#{window_name}' 2>/dev/null | paste -sd,; }
first_window() { tmux list-windows -t '=devbox:' -F '#{window_index} #{window_name}' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2; }
field() { jq -r ".$2" "$AGENT_STATUS_DIR/$1.json" 2>/dev/null; } # ID FIELD
# wait_state ID STATE: wait up to 15 s for the row to reach STATE
wait_state() {
  local i
  for ((i = 0; i < 150; i++)); do
    [[ $(field "$1" state) == "$2" ]] && return 0
    sleep 0.1
  done
  return 1
}

# --- agent-run: no session yet, the agent is running
touch "$HOME/gate"
echo 0 >"$HOME/stub-exit"
check_eq "no tmux session before the first run" "$(sessions)" ""
agent-run --agent claude --task "fix the bug"; rc=$?
check_eq "agent-run exit status" "$rc" "0"
check_eq "agent-run created the session devbox" "$(sessions)" "devbox"
check_eq "the board window stays the first window" "$(first_window)" "board"
check_eq "a window is named by the id" "$(windows)" "board,claude-1"
wait_state claude-1 working && ok "row is working while the agent runs" || fail "row claude-1 never became working"
check_eq "row id" "$(field claude-1 id)" "claude-1"
check_eq "row agent" "$(field claude-1 agent)" "claude"
check_eq "row task" "$(field claude-1 task)" "fix the bug"
check_eq "row window is the id" "$(field claude-1 window)" "claude-1"
check_eq "row log is <status dir>/<id>.log" "$(field claude-1 log)" "$AGENT_STATUS_DIR/claude-1.log"
check_has "row pid is a live process" "$(field claude-1 pid)" '^[0-9]+$'
[[ -d /proc/$(field claude-1 pid) ]] && ok "row pid is alive" || fail "row pid is not alive"
rm -f "$HOME/gate"
wait_state claude-1 done && ok "exit 0 leaves the row done" || fail "claude-1 is '$(field claude-1 state)', want done"
check_eq "the window is gone with the agent" "$(windows)" "board"
log=$AGENT_STATUS_DIR/claude-1.log
[[ -f $log && ! -L $log ]] && ok "the log is a regular file" || fail "no regular log file at $log"
check_has "the log has the agent output" "$(cat "$log" 2>/dev/null)" 'stub-claude fix the bug'
check_has "the agent ran in ~/work by default" "$(cat "$log" 2>/dev/null)" "cwd=$HOME/work"
check_has "the agent knows its row id" "$(cat "$log" 2>/dev/null)" 'run-id=claude-1'
check_eq "the log is private" "$(stat -c %a "$log")" "600"

# --- exit status 1 leaves failed; --dir; the next id
echo 1 >"$HOME/stub-exit"
agent-run --agent claude --task "will fail" --dir "$tmp/elsewhere"
wait_state claude-2 failed && ok "exit 1 leaves the row failed" || fail "claude-2 is '$(field claude-2 state)', want failed"
check_has "--dir is the working directory" "$(cat "$AGENT_STATUS_DIR/claude-2.log")" "cwd=$tmp/elsewhere"
echo 0 >"$HOME/stub-exit"

# --- opencode
agent-run --agent opencode --task "write docs"
wait_state opencode-1 done && ok "opencode run ends done" || fail "opencode-1 is '$(field opencode-1 state)'"
check_has "opencode gets the task as --prompt" "$(cat "$AGENT_STATUS_DIR/opencode-1.log")" 'stub-opencode --prompt=write docs'
check_eq "opencode row agent" "$(field opencode-1 agent)" "opencode"

# --- the smallest unused number is taken again
agent-status rm claude-1
rm -f "$AGENT_STATUS_DIR/claude-1.log"
agent-run --agent claude --task "again"
wait_state claude-1 done && ok "the smallest unused id is reused" || fail "claude-1 not reused"
check_eq "the next id skips rows that exist" "$(field claude-2 task)" "will fail"

# --- two (here six) concurrent calls get distinct ids
touch "$HOME/gate"
for i in 1 2 3 4 5 6; do agent-run --agent claude --task "parallel $i" & done
wait
ids=$(agent-status list --json | jq -r '.[] | select(.task | startswith("parallel")) | .id' | sort | paste -sd,)
check_eq "concurrent calls get distinct ids" "$ids" "claude-3,claude-4,claude-5,claude-6,claude-7,claude-8"
check_eq "concurrent calls open one window each" "$(windows | tr ',' '\n' | grep -c '^claude-[3-8]$')" "6"
rm -f "$HOME/gate"
for n in 3 4 5 6 7 8; do wait_state "claude-$n" done || fail "claude-$n never ended done"; done
ok "concurrent runs ended"

# --- the task reaches the agent as one argument, never through a shell
task="a'b\"\$(touch $tmp/pwned) \`touch $tmp/pwned2\`; echo \$HOME"
agent-run --agent claude --task "$task"
wait_state claude-9 done || fail "claude-9 not done"
check_has "a hostile task is passed verbatim" "$(cat "$AGENT_STATUS_DIR/claude-9.log")" 'stub-claude a.b".\(touch .*pwned\) `touch .*pwned2`; echo \$HOME'
[[ ! -e $tmp/pwned && ! -e $tmp/pwned2 ]] && ok "a hostile task runs nothing" || fail "a hostile task ran a command"

# --- a rejected call leaves no row, no window, no log
before=$(ls -A "$AGENT_STATUS_DIR" | grep -vc '^\.' || true)
rejected() { # NAME ARGS...
  local n=$1
  shift
  agent-run "$@" 2>"$tmp/err" >/dev/null; rc=$?
  check_eq "rejected ($n): exit 2" "$rc" "2"
  [[ -s $tmp/err ]] && ok "rejected ($n): a message on stderr" || fail "rejected ($n): no message"
}
rejected no-task --agent claude
rejected empty-task --agent claude --task ""
rejected no-agent --task x
rejected bad-agent --agent rm --task x
rejected bad-dir --agent claude --task x --dir "$tmp/none"
rejected dash-task --agent claude --task "--help"
rejected newline-task --agent claude --task $'a\nb'
rejected long-task --agent claude --task "$(printf 'x%.0s' $(seq 1 201))"
rejected unknown-option --agent claude --task x --bogus 1
rejected missing-value --agent claude --task
after=$(ls -A "$AGENT_STATUS_DIR" | grep -vc '^\.' || true)
check_eq "rejected calls leave no file behind" "$after" "$before"

# --- an existing session without the agent window: the window is added, the board stays first
tmux kill-server 2>/dev/null
tmux new-session -d -s devbox -n board 'sleep 600'
tmux new-window -d -t '=devbox:' -n other 'sleep 600'
touch "$HOME/gate"
agent-run --agent claude --task "second session test"
check_has "an existing session gets the new window" "$(windows)" '(^|,)claude-10(,|$)'
check_eq "an existing session keeps one board" "$(windows | tr ',' '\n' | grep -c '^board$')" "1"
rm -f "$HOME/gate"
wait_state claude-10 done || fail "claude-10 not done"

# --- API keys: tmux runs the window command in a non-interactive shell, so the wrapper loads
# $XDG_RUNTIME_DIR/devbox-env itself, as text (like devbox-load-env): three known keys, a regular
# file owned by the user with no group/world bit, values of [A-Za-z0-9_.-]+, first line of a key
# wins, never sourced.
env_file=$XDG_RUNTIME_DIR/devbox-env
# run_agent: runs a stub agent through agent-run; sets run_id and run_log (the stub's output).
run_agent() {
  run_id=$(agent-run --agent claude --task "env test") || fail "agent-run failed"
  wait_state "$run_id" done && ok "the agent ran ($run_id done)" || fail "$run_id is '$(field "$run_id" state)', want done"
  run_log=$(tr -d '\r' <"$AGENT_STATUS_DIR/$run_id.log" 2>/dev/null) # script's terminal adds CRs
}
write_env() { # MODE (content on stdin)
  rm -f "$env_file"
  (umask 077 && cat >"$env_file")
  chmod "$1" "$env_file"
}
write_env 600 <<'EOF'
DEEPSEEK_API_KEY=ds-key.1
OPENROUTER_API_KEY=or_key-2
GITHUB_TOKEN=ghp_Tok3n
EVIL=1
PATH=/evil
DEEPSEEK_API_KEY=second
EOF
run_agent
check_has "wrapper: the three keys reach the agent" "$run_log" '^keys=ds-key\.1\|or_key-2\|ghp_Tok3n$'
check_has "wrapper: an unrelated key (EVIL) is ignored" "$run_log" '^evil=$'
check_eq "wrapper: PATH from the file is ignored" "$(grep -c '^stub-path=.*/evil' <<<"$run_log" || true)" "0"
check_has "wrapper: the agent still knows its row id" "$run_log" "^run-id=$run_id\$"

# hostile values and a bad first line: unset, nothing runs, the agent still starts
write_env 600 <<EOF
DEEPSEEK_API_KEY=\$(touch $tmp/pwned)
OPENROUTER_API_KEY=a;touch $tmp/pwned2
GITHUB_TOKEN=bad value
DEEPSEEK_API_KEY=good-second-line
EOF
run_agent
check_has "wrapper: hostile values are not exported" "$run_log" '^keys=\|\|$'
[[ ! -e $tmp/pwned && ! -e $tmp/pwned2 ]] && ok "wrapper: the env file is never executed" || fail "wrapper: the env file ran a command"
write_env 600 <<'EOF'
export DEEPSEEK_API_KEY=a
OPENROUTER_API_KEY="quoted"
 GITHUB_TOKEN=indented
EOF
run_agent
check_has "wrapper: only plain KEY=value lines count" "$run_log" '^keys=\|\|$'

# wrong mode: nothing is read, the agent still runs
for mode in 644 640 604 660 666; do
  write_env "$mode" <<'EOF'
DEEPSEEK_API_KEY=ds-key
OPENROUTER_API_KEY=or-key
GITHUB_TOKEN=gh-key
EOF
  run_agent
  check_has "wrapper: mode $mode exports nothing" "$run_log" '^keys=\|\|$'
done

# a symlink to a good file: nothing is read
rm -f "$env_file"
(umask 077 && printf 'DEEPSEEK_API_KEY=via-link\nGITHUB_TOKEN=via-link\n' >"$tmp/real-env")
ln -s "$tmp/real-env" "$env_file"
run_agent
check_has "wrapper: a symlinked env file exports nothing" "$run_log" '^keys=\|\|$'
# a directory, a missing file: nothing, and no failure
rm -f "$env_file"
mkdir -m 700 "$env_file"
run_agent
check_has "wrapper: a directory exports nothing" "$run_log" '^keys=\|\|$'
rmdir "$env_file"
run_agent
check_has "wrapper: no env file exports nothing" "$run_log" '^keys=\|\|$'

# a key missing from the file stays unset
write_env 600 <<'EOF'
GITHUB_TOKEN=only-github
EOF
run_agent
check_has "wrapper: each key on its own" "$run_log" '^keys=\|\|only-github$'
rm -f "$env_file"

# --- agent-hook: one event, one state
hook() { printf '%s' "$2" | agent-hook "$1"; } # EVENT JSON
sid=1234abcd-0000-4000-8000-000000000000
j() { printf '{"session_id":"%s","cwd":"/home/abel/work/x","hook_event_name":"%s"}' "$sid" "$1"; }
out=$(hook SessionStart "$(j SessionStart)"); rc=$?
check_eq "agent-hook exit status" "$rc" "0"
check_eq "agent-hook prints nothing (stdout would reach the model)" "$out" ""
check_eq "SessionStart -> working" "$(field claude-1234abcd state)" "working"
check_eq "hook row agent" "$(field claude-1234abcd agent)" "claude"
check_eq "hook row machine" "$(field claude-1234abcd machine)" "devbox"
check_has "hook row task names the directory" "$(field claude-1234abcd task)" '/home/abel/work/x'
for pair in Notification:waiting Stop:waiting UserPromptSubmit:working SessionEnd:done; do
  ev=${pair%%:*}
  want=${pair##*:}
  out=$(hook "$ev" "$(j "$ev")"); rc=$?
  check_eq "$ev exit status" "$rc" "0"
  check_eq "$ev prints nothing" "$out" ""
  check_eq "$ev -> $want" "$(field claude-1234abcd state)" "$want"
done
check_eq "later events keep the task" "$(field claude-1234abcd task)" "claude in /home/abel/work/x"

# AGENT_HOOK_DISABLE=1 (set by job-triage for its claude): no row, no output, exit 0, on every event.
for ev in SessionStart UserPromptSubmit Notification Stop SessionEnd; do
  out=$(printf '{"session_id":"d15ab1ed-0000","cwd":"/x"}' | AGENT_HOOK_DISABLE=1 agent-hook "$ev"); rc=$?
  check_eq "AGENT_HOOK_DISABLE=1 $ev: exit status" "$rc" "0"
  check_eq "AGENT_HOOK_DISABLE=1 $ev: prints nothing" "$out" ""
done
[[ ! -e $AGENT_STATUS_DIR/claude-d15ab1ed.json ]] && ok "AGENT_HOOK_DISABLE=1 writes no row" || fail "a row was written with AGENT_HOOK_DISABLE=1"
# any other value, or none, behaves as before
printf '{"session_id":"d15ab1ed-0000","cwd":"/x"}' | AGENT_HOOK_DISABLE=0 agent-hook SessionStart
check_eq "AGENT_HOOK_DISABLE=0 still writes the row" "$(field claude-d15ab1ed state)" "working"

# the id is claude-<first 8 characters of session_id>, lower case
hook SessionStart '{"session_id":"ABCDEF12-3456","cwd":"/x"}'
check_eq "id is lower case, 8 characters" "$(field claude-abcdef12 state)" "working"

# a session started by agent-run updates the row of agent-run
agent-status set --id claude-77 --agent claude --task "mine" --state working --pid 1 --window claude-77
out=$(printf '{"session_id":"99999999-aaaa","cwd":"/x"}' | AGENT_RUN_ID=claude-77 agent-hook Stop); rc=$?
check_eq "hook with AGENT_RUN_ID exit status" "$rc" "0"
check_eq "hook with AGENT_RUN_ID updates that row" "$(field claude-77 state)" "waiting"
check_eq "hook with AGENT_RUN_ID keeps its task" "$(field claude-77 task)" "mine"
check_eq "hook with AGENT_RUN_ID keeps its window" "$(field claude-77 window)" "claude-77"
[[ ! -e $AGENT_STATUS_DIR/claude-99999999.json ]] && ok "hook with AGENT_RUN_ID makes no second row" || fail "second row for the same agent"
printf '{"session_id":"99999999-aaaa","cwd":"/x"}' | AGENT_RUN_ID='../evil' agent-hook Stop
check_eq "a bad AGENT_RUN_ID falls back to the session id" "$(field claude-99999999 state)" "waiting"

# Ctrl-X marks the row `stopped` and kills the window; Claude Code's SessionEnd then runs. A
# stopped row of agent-run stays stopped, on every event, and is not even rewritten.
agent-status set --id claude-78 --agent claude --task "killed" --state stopped --pid 1 --window claude-78
sleep 1
before=$(cat "$AGENT_STATUS_DIR/claude-78.json")
for ev in SessionEnd Stop Notification UserPromptSubmit SessionStart; do
  out=$(printf '{"session_id":"88888888-aaaa","cwd":"/x"}' | AGENT_RUN_ID=claude-78 agent-hook "$ev"); rc=$?
  check_eq "hook $ev on a stopped row: exit status" "$rc" "0"
  check_eq "hook $ev on a stopped row: prints nothing" "$out" ""
done
check_eq "hook events leave a stopped row exactly as it was" "$(cat "$AGENT_STATUS_DIR/claude-78.json")" "$before"
[[ ! -e $AGENT_STATUS_DIR/claude-88888888.json ]] && ok "hook on a stopped row makes no second row" || fail "second row for a stopped agent"
# the other order: SessionEnd first (done), then Ctrl-X (stopped) wins, as a plain write
agent-status set --id claude-79 --agent claude --task "ended" --state working --pid 1 --window claude-79
printf '{"session_id":"77777777-aaaa","cwd":"/x"}' | AGENT_RUN_ID=claude-79 agent-hook SessionEnd
check_eq "SessionEnd on a working row of agent-run -> done" "$(field claude-79 state)" "done"
agent-status set --id claude-79 --state stopped
check_eq "stopped after done stays stopped" "$(field claude-79 state)" "stopped"
# only `stopped` blocks the hook: waiting, failed and done rows are still updated
for st in waiting failed done lost; do
  agent-status set --id claude-80 --agent claude --task "t" --state "$st" --pid 1 --window claude-80
  printf '{"session_id":"66666666-aaaa","cwd":"/x"}' | AGENT_RUN_ID=claude-80 agent-hook UserPromptSubmit
  check_eq "hook updates a $st row" "$(field claude-80 state)" "working"
done
# an unreadable row is not `stopped`: the hook writes it
printf 'not json' >"$AGENT_STATUS_DIR/claude-81.json"
printf '{"session_id":"55555555-aaaa","cwd":"/x"}' | AGENT_RUN_ID=claude-81 agent-hook Stop
check_eq "hook rewrites an unreadable row" "$(field claude-81 state)" "waiting"

# garbage: exit 0, nothing written, nothing printed
snapshot() { ls -A "$AGENT_STATUS_DIR" | grep -v '^\.' | sort | paste -sd,; }
before=$(snapshot)
garbage() { # NAME EVENT STDIN
  local o r
  o=$(printf '%s' "$3" | agent-hook "$2" 2>&1); r=$?
  check_eq "garbage ($1): exit 0" "$r" "0"
  check_eq "garbage ($1): prints nothing" "$o" ""
}
garbage not-json SessionStart 'this is not json'
garbage empty SessionStart ''
garbage array Stop '[1,2,3]'
garbage no-session Stop '{"cwd":"/x"}'
garbage session-not-string Stop '{"session_id":12345678}'
garbage short-session Stop '{"session_id":"abc"}'
garbage hostile-session Stop '{"session_id":"../../etc/passwd"}'
garbage session-newline Stop $'{"session_id":"abcdefgh\\nij"}'
garbage unknown-event Whatever "$(j Whatever)"
garbage no-event ""  "$(j Stop)"
garbage binary SessionStart "$(head -c 300 /dev/urandom | tr -d '\0')"
agent-hook </dev/null >/dev/null 2>&1; check_eq "agent-hook with no argument and no stdin exits 0" "$?" "0"
check_eq "garbage writes nothing" "$(snapshot)" "$before"
# an unwritable status directory must not make the hook fail
o=$(printf '%s' "$(j Stop)" | AGENT_STATUS_DIR=/proc/nope/agents agent-hook Stop 2>&1); r=$?
check_eq "unwritable status dir: exit 0" "$r" "0"
check_eq "unwritable status dir: prints nothing" "$o" ""
# a very long task from a long cwd is cut, not rejected
long=$(printf 'd%.0s' $(seq 1 300))
printf '{"session_id":"11112222-x","cwd":"/%s"}' "$long" | agent-hook SessionStart
check_eq "a long cwd still makes a row" "$(field claude-11112222 state)" "working"

# --- managed settings
settings=${MANAGED_SETTINGS:-/nonexistent}
jq -e . "$settings" >/dev/null 2>&1 && ok "managed-settings.json parses" || fail "managed-settings.json does not parse"
for ev in SessionStart Notification Stop UserPromptSubmit SessionEnd; do
  cmd=$(jq -r --arg ev "$ev" '.hooks[$ev][0].hooks[0] | select(.type == "command") | .command' "$settings" 2>/dev/null)
  check_eq "settings: $ev calls agent-hook $ev" "$cmd" "$AGENT_HOOK_BIN $ev"
done
check_eq "settings: exactly the five events" "$(jq -r '.hooks | keys | join(",")' "$settings" 2>/dev/null)" "Notification,SessionEnd,SessionStart,Stop,UserPromptSubmit"
check_eq "settings: a timeout bounds every hook" "$(jq -r '[.hooks[][0].hooks[0].timeout | numbers] | length' "$settings" 2>/dev/null)" "5"
check_eq "settings: nothing but hooks" "$(jq -r 'keys | join(",")' "$settings" 2>/dev/null)" "hooks"
[[ -x $AGENT_HOOK_BIN ]] && ok "settings: agent-hook path is executable" || fail "settings: $AGENT_HOOK_BIN is not executable"

echo
if ((fails > 0)); then echo "$fails test(s) failed" >&2; exit 1; fi
echo "all tests passed"
