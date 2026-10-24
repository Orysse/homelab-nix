#!/usr/bin/env bash
# Tests for board, devbox-session and the zsh login snippet, run by checks.<system>.devbox-session.
# On PATH: board, devbox-session, agent-status, tmux, fzf, zsh, script, jq, coreutils.
# $LOGIN_SNIPPET is the generated programs.zsh.loginShellInit text.
# tmux runs on a private socket (TMUX_TMPDIR); fzf is replaced by stubs, except for one test
# that feeds the real fzf the arguments board gave the stub.
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
  if grep -qE -- "$3" <<<"$2"; then fail "$1: unexpected match for '$3' in: $2"; else ok "$1"; fi
}

tmp=$(mktemp -d)
export HOME=$tmp/home
export TMUX_TMPDIR=$tmp/tmux
export TERM=xterm
export SHELL
SHELL=$(command -v bash)
export AGENT_STATUS_DIR=$tmp/agents
unset TMUX SSH_CONNECTION
mkdir -p "$HOME" "$TMUX_TMPDIR" "$AGENT_STATUS_DIR"
trap 'tmux kill-server 2>/dev/null; rm -rf "$tmp"' EXIT

real_fzf=$(command -v fzf)
base_path=$PATH
stub_list=$tmp/stub-list # fzf that records its arguments and echoes its input
stub_sleep=$tmp/stub-sleep # fzf that stays alive, as the board window must
mkdir -p "$stub_list" "$stub_sleep"
# The sandbox has no /usr/bin/env: the stubs get the absolute path of bash as interpreter.
{
  echo "#!$SHELL"
  echo 'printf "%s\0" "$@" >"$FZF_ARGS_FILE"'
  echo 'cat'
} >"$stub_list/fzf"
{
  echo "#!$SHELL"
  echo 'exec sleep 600'
} >"$stub_sleep/fzf"
chmod +x "$stub_list/fzf" "$stub_sleep/fzf"

windows() { tmux list-windows -t "=$1:" -F '#{window_name}' 2>/dev/null | paste -sd,; }
active() { tmux list-windows -t "=$1:" -F '#{?window_active,#{window_name},}' 2>/dev/null | grep . || true; }
sessions() { tmux list-sessions -F '#{session_name}' 2>/dev/null | paste -sd, || true; }
session_up() { PATH=$stub_sleep:$base_path devbox-session; }

# --- devbox-session: create, then reuse
session_up; rc=$?
check_eq "devbox-session exit without a terminal" "$rc" "0"
check_eq "session devbox exists" "$(sessions)" "devbox"
check_eq "window 0 is board" "$(tmux list-windows -t '=devbox:' -F '#{window_index}:#{window_name}')" "0:board"
session_up; rc=$?
check_eq "second call exit" "$rc" "0"
check_eq "second call makes no second session" "$(sessions)" "devbox"
check_eq "second call makes no second window" "$(windows devbox)" "board"

# --- devbox-session: eight logins at once make one session
tmux kill-server 2>/dev/null
for _ in $(seq 1 8); do session_up & done
wait
check_eq "concurrent calls make one session" "$(sessions)" "devbox"
check_eq "concurrent calls make one window" "$(windows devbox)" "board"

# --- devbox-session with a terminal attaches, a second one attaches to the same session
tmux kill-server 2>/dev/null
cat >"$tmp/attach.sh" <<EOF
export PATH=$stub_sleep:$base_path
exec devbox-session
EOF
for n in 1 2; do
  (sleep 8 | script -qec "bash $tmp/attach.sh" /dev/null >/dev/null 2>&1) &
  for _ in $(seq 1 50); do
    [[ $(tmux list-clients 2>/dev/null | wc -l) -ge $n ]] && break
    sleep 0.1
  done
  check_eq "terminal login $n attaches a client" "$(tmux list-clients 2>/dev/null | wc -l)" "$n"
  check_eq "terminal login $n makes no second session" "$(sessions)" "devbox"
done
tmux kill-server 2>/dev/null
wait

# --- zsh login snippet: only an interactive SSH login with a terminal, outside tmux, starts it
stubs=$tmp/stub-session
mkdir -p "$stubs"
printf "#!%s\necho SESSION-STARTED\n" "$SHELL" >"$stubs/devbox-session"
chmod +x "$stubs/devbox-session"
# zsh_tty FLAGS runs the snippet in zsh behind a pty (script) and prints what came out; zsh_notty has no pty.
cat >"$tmp/zsh-run.sh" <<EOF
export PATH=$stubs:$base_path
zsh -f \$1 -c "source $LOGIN_SNIPPET; echo AFTER"
EOF
zsh_tty() { script -qec "bash $tmp/zsh-run.sh '$1'" /dev/null </dev/null 2>&1 | tr -d '\r'; }
zsh_notty() { PATH=$stubs:$base_path zsh -f $1 -c "source $LOGIN_SNIPPET; echo AFTER" </dev/null 2>&1; }

export SSH_CONNECTION="10.0.0.1 5000 10.0.0.2 22"
out=$(zsh_tty "-l -i")
check_has "login hook: interactive ssh login starts the session" "$out" '^SESSION-STARTED$'
check_lacks "login hook: the shell was replaced (exec)" "$out" 'AFTER'
out=$(TMUX=/tmp/tmux-1/default,1,0 zsh_tty "-l -i")
check_has "login hook: not inside tmux" "$out" 'AFTER'
check_lacks "login hook: no nesting in tmux" "$out" 'SESSION-STARTED'
out=$(zsh_tty "-i")
check_lacks "login hook: a non-login shell does not start it" "$out" 'SESSION-STARTED'
out=$(zsh_notty "-l -i")
check_lacks "login hook: no tty on stdin (ssh host cmd)" "$out" 'SESSION-STARTED'
out=$(zsh_notty "-l")
check_eq "login hook: non-interactive login prints nothing but the command" "$out" "AFTER"
unset SSH_CONNECTION
out=$(zsh_tty "-l -i")
check_lacks "login hook: not an ssh login" "$out" 'SESSION-STARTED'
check_has "login hook: a local login keeps its shell" "$out" 'AFTER'

# --- board: hint when empty, rows when there are some
run_board() { PATH=$stub_list:$base_path FZF_ARGS_FILE=$tmp/fzf-args "$@"; }
out=$(AGENT_STATUS_DIR=$tmp/missing run_board board); rc=$?
check_eq "board with a missing dir exits 0" "$rc" "0"
check_has "board with a missing dir prints the hint" "$out" 'no agents yet'
check_eq "board with a missing dir prints one line" "$(wc -l <<<"$out")" "1"
[[ ! -e $tmp/missing ]] && ok "board does not create the status directory" || fail "board created the directory"
out=$(run_board board); rc=$?
check_eq "board with an empty dir exits 0" "$rc" "0"
check_has "board with an empty dir prints the hint" "$out" 'no agents yet'

agent-status set --id claude-1 --agent claude --machine devbox --task "fix the bug" --state working
agent-status set --id claude-2 --agent claude --machine laptop --task "write docs" --state waiting
out=$(run_board board); rc=$?
check_eq "board with two rows exits 0" "$rc" "0"
check_has "board lists the first row" "$out" '^claude-1 +claude +devbox +fix the bug +working +[0-9]+s$'
check_has "board lists the second row" "$out" '^claude-2 +claude +laptop +write docs +waiting +[0-9]+s$'
check_lacks "board shows no hint with rows" "$out" 'no agents yet'
check_eq "board prints a header and two rows" "$(wc -l <<<"$out")" "3"

# the arguments given to fzf: keys, refresh, and the real fzf accepts them
mapfile -d '' fzf_args <"$tmp/fzf-args"
joined=$(printf '%s\n' "${fzf_args[@]}")
check_has "fzf key enter" "$joined" '(^|,)enter:execute\(.* _enter \{1\}\)'
check_has "fzf key ctrl-l" "$joined" 'ctrl-l:execute\(.* _log \{1\}\)'
check_has "fzf key ctrl-x" "$joined" 'ctrl-x:.*_kill \{1\}'
check_has "fzf key ctrl-n" "$joined" 'ctrl-n:execute\(.* _new\)'
check_has "fzf refreshes every 2 s" "$joined" 'every\(2\):reload-sync\(.* _list\)'
"$real_fzf" "${fzf_args[@]}" --filter zzz </dev/null >/dev/null 2>"$tmp/fzf-err"; rc=$?
if [[ $rc -eq 0 || $rc -eq 1 ]]; then ok "real fzf accepts the arguments"; else fail "real fzf rejected the arguments (exit $rc): $(cat "$tmp/fzf-err")"; fi

# --- Enter: window devbox:<id> only, the row's window field is never used
tmux kill-server 2>/dev/null
session_up
tmux new-window -d -t '=devbox:' -n claude-1 'sleep 600'
tmux new-window -d -t '=devbox:' -n k 'sleep 600'
tmux new-session -d -s other -n w0 'sleep 600'
tmux new-window -d -t '=other:' -n w1 'sleep 600'
tmux select-window -t '=other:w1'
tmux select-window -t '=devbox:board'

agent-status set --id claude-1 --window other:0 --state working
board _enter claude-1 2>/dev/null
check_eq "Enter selects devbox:<id>" "$(active devbox)" "claude-1"
check_eq "Enter ignores the row's window (other:0)" "$(active other)" "w1"

tmux select-window -t '=devbox:board'
agent-status set --id claude-1 --window 'devbox:k' --state working
board _enter claude-1 2>/dev/null
check_eq "Enter ignores the row's window (devbox:k)" "$(active devbox)" "claude-1"

tmux select-window -t '=devbox:board'
agent-status set --id 1 --window 'devbox:k' --state working
board _enter 1 2>/dev/null
check_eq "id 1 is a name, not the window index 1" "$(active devbox)" "board"
tmux new-window -d -t '=devbox:' -n 1 'sleep 600'
board _enter 1 2>/dev/null
check_eq "a window really named 1 is selected" "$(active devbox)" "1"
tmux select-window -t '=devbox:board'
board _enter '../x' 2>/dev/null
board _enter 'a:b' 2>/dev/null
board _enter '' 2>/dev/null
board _enter 'claude-1;k' 2>/dev/null
check_eq "hostile ids select nothing" "$(active devbox)" "board"
board _enter nosuchrow 2>/dev/null
check_eq "unknown id selects nothing" "$(active devbox)" "board"

# --- logs: only a regular file under the status directory is opened
secret=$tmp/secret.txt
echo "TOP-SECRET-CONTENT" >"$secret"
mkdir -p "$tmp/agents-evil" "$AGENT_STATUS_DIR/logs"
echo "SIBLING-CONTENT" >"$tmp/agents-evil/x.log"
echo "hello from the log" >"$AGENT_STATUS_DIR/logs/ok.log"
ln -s "$secret" "$AGENT_STATUS_DIR/link-out.log"
ln -s "$AGENT_STATUS_DIR/logs/ok.log" "$AGENT_STATUS_DIR/link-in.log"
ln -s "$tmp" "$AGENT_STATUS_DIR/dirlink"
mkfifo "$AGENT_STATUS_DIR/fifo.log"

# refused LOG: prints nothing on stdout, a short message on stderr, both for _log and _enter
refused() { # NAME LOG
  local n=$1 log=$2 out err
  agent-status set --id "ref-$n" --window "other:0" --state done --log "$log"
  out=$(timeout 5 board _log "ref-$n" 2>"$tmp/err" </dev/null)
  err=$(<"$tmp/err")
  check_eq "log refused ($n): nothing opened" "$out" ""
  [[ -n $err && $(wc -l <<<"$err") -eq 1 ]] && ok "log refused ($n): one-line message" || fail "log refused ($n): message was '$err'"
  out=$(timeout 5 board _enter "ref-$n" 2>/dev/null </dev/null)
  check_eq "Enter on refused log ($n): nothing opened" "$out" ""
}
refused passwd /etc/passwd
refused symlink-out "$AGENT_STATUS_DIR/link-out.log"
refused traversal "$AGENT_STATUS_DIR/../secret.txt"
refused traversal2 "$AGENT_STATUS_DIR/logs/../../secret.txt"
refused sibling "$tmp/agents-evil/x.log"
refused dir-symlink "$AGENT_STATUS_DIR/dirlink/secret.txt"
refused fifo "$AGENT_STATUS_DIR/fifo.log"
refused directory "$AGENT_STATUS_DIR/logs"
refused relative "logs/ok.log"
refused missing "$AGENT_STATUS_DIR/logs/none.log"
refused status-dir "$AGENT_STATUS_DIR"
printf '{"id":"ref-nl","log":"/x\\n%s","state":"done"}\n' "$secret" >"$AGENT_STATUS_DIR/ref-nl.json"
check_eq "log refused (newline in path)" "$(timeout 5 board _log ref-nl 2>/dev/null </dev/null)" ""
printf '{"id":"ref-num","log":42,"state":"done"}\n' >"$AGENT_STATUS_DIR/ref-num.json"
check_eq "log refused (not a string)" "$(timeout 5 board _log ref-num 2>/dev/null </dev/null)" ""
agent-status set --id ref-none --state done
check_eq "no log field: nothing opened" "$(timeout 5 board _log ref-none 2>/dev/null </dev/null)" ""

# allowed
agent-status set --id ok --state done --log "$AGENT_STATUS_DIR/logs/ok.log"
check_eq "log under the status dir is opened (Ctrl-L)" "$(timeout 5 board _log ok </dev/null 2>&1)" "hello from the log"
check_eq "no window: Enter opens the log" "$(timeout 5 board _enter ok </dev/null 2>&1)" "hello from the log"
agent-status set --id ok-link --state done --log "$AGENT_STATUS_DIR/link-in.log"
check_eq "symlink staying inside the status dir is opened" "$(timeout 5 board _log ok-link </dev/null 2>&1)" "hello from the log"
ln -s "$AGENT_STATUS_DIR" "$tmp/statusdir-link"
agent-status set --id ok-dirlink --state done --log "$AGENT_STATUS_DIR/logs/ok.log"
check_eq "status dir given as a symlink works" \
  "$(AGENT_STATUS_DIR=$tmp/statusdir-link timeout 5 board _log ok-dirlink </dev/null 2>&1)" "hello from the log"
# a row with a window and a log: Enter prefers the window, and does not print the log
tmux select-window -t '=devbox:board'
agent-status set --id k --state working --log "$AGENT_STATUS_DIR/logs/ok.log"
check_eq "window exists: Enter does not open the log" "$(timeout 5 board _enter k </dev/null 2>&1)" ""
check_eq "window exists: Enter selects it" "$(active devbox)" "k"

# --- Ctrl-X: kill devbox:<id> and mark stopped, never the row's window, never board
tmux select-window -t '=devbox:board'
agent-status set --id k --window other:w1 --state working
board _kill k 2>/dev/null
check_eq "Ctrl-X kills the window of the id" "$(windows devbox | tr ',' '\n' | grep -cx k || true)" "0"
check_eq "Ctrl-X marks the row stopped" "$(jq -r .state "$AGENT_STATUS_DIR/k.json")" "stopped"
check_eq "Ctrl-X leaves the row's window alone" "$(windows other)" "w0,w1"
agent-status set --id board --window other:w0 --state working
board _kill board 2>/dev/null
check_has "Ctrl-X never kills the board window" "$(windows devbox)" '(^|,)board(,|$)'
check_eq "Ctrl-X on board leaves the row alone" "$(jq -r .state "$AGENT_STATUS_DIR/board.json")" "working"
board _kill '../x' 2>/dev/null
board _kill nosuchrow 2>/dev/null
[[ ! -e $AGENT_STATUS_DIR/nosuchrow.json ]] && ok "Ctrl-X on an unknown id creates no row" || fail "Ctrl-X created a row"

echo
if ((fails > 0)); then echo "$fails test(s) failed" >&2; exit 1; fi
echo "all tests passed"
