# shellcheck shell=bash
# board: fzf table over `agent-status list`, run in window 0 of the tmux session `devbox`.
#   board                       the table (Enter jump, Ctrl-L log, Ctrl-N new agent, Ctrl-X stop)
# fzf calls this script back with the internal subcommands _list, _enter ID, _log ID, _kill ID, _new.
#
# Rows may come from other machines through a restricted SSH key, so every field of a row is
# untrusted. Of a row only the id picks what happens, and it is checked against the id rule first:
#   - the tmux target is always devbox:<id>, the row's `window` field is never read;
#   - a log is opened only when its real path (links resolved) is a regular file under the
#     status directory; anything else gets a one-line message.

# Character classes in the id check must follow UTF-8, not bytes.
export LC_ALL=C.UTF-8

dir=${AGENT_STATUS_DIR:-$HOME/.local/state/agents}
export AGENT_STATUS_DIR=$dir # agent-status and agent-run see the same directory
session=devbox
max_file=65536 # a row is far smaller; anything bigger is not a row
self=$0
hint='no agents yet: Ctrl-N starts one'

# msg TEXT: one line on stderr; on a terminal it stays up long enough to read, as fzf redraws after.
msg() {
  echo "board: $*" >&2
  if [[ -t 2 ]]; then sleep 2; fi
}

valid_id() {
  [[ ${1:-} =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]
}

# row_file ID: the path of the row, only when it is a plain file in the status directory.
row_file() {
  local f=$dir/$1.json
  [[ -f $f && ! -L $f ]] || return 1
  printf '%s\n' "$f"
}

# row_log ID: prints the row's log string, fails when there is none.
row_log() {
  local f
  f=$(row_file "$1") || return 1
  head -c "$max_file" "$f" 2>/dev/null |
    jq -er 'select(type == "object") | .log | select(type == "string" and . != "")'
}

# window_id ID: prints the tmux id (@N) of the window named ID in session devbox. tmux would also take
# a bare "1" for the window index, even with an "=" prefix, so the names are compared here.
window_id() {
  local wid wname
  while read -r wid wname; do
    if [[ $wname == "$1" ]]; then
      printf '%s\n' "$wid"
      return 0
    fi
  done < <(tmux list-windows -t "=$session:" -F '#{window_id} #{window_name}' 2>/dev/null)
  return 1
}

# open_log ID: pages the row's log if, and only if, it resolves to a regular file in the status dir.
open_log() {
  local id=$1 log real real_dir fd_path
  if ! log=$(row_log "$id"); then
    msg "$id: no log"
    return 0
  fi
  if [[ $log != /* || $log == *[[:cntrl:]]* ]]; then
    msg "$id: log path refused"
    return 0
  fi
  if ! real_dir=$(realpath -e -- "$dir" 2>/dev/null) || ! real=$(realpath -e -- "$log" 2>/dev/null); then
    msg "$id: log not found"
    return 0
  fi
  if [[ $real != "$real_dir"/* || ! -f $real ]]; then
    msg "$id: log is not a regular file under $dir, not opened"
    return 0
  fi
  # Open once, then check the open file, so a link swapped in after the check is not followed.
  exec 8<"$real"
  fd_path=$(realpath -e -- /proc/self/fd/8 2>/dev/null) || fd_path=""
  if [[ $fd_path != "$real_dir"/* || ! -f /proc/self/fd/8 ]]; then
    exec 8<&-
    msg "$id: log changed while opening, not opened"
    return 0
  fi
  # Secure mode: no shell escape, no editor, no preprocessor from the environment.
  LESSSECURE=1 LESSOPEN="" LESSCLOSE="" less <&8 || true
  exec 8<&-
}

cmd_list() {
  local rows
  agent-status reconcile 2>/dev/null || true
  rows=$(agent-status list)
  if [[ -z $rows ]]; then
    printf '%s\n' "$hint"
    return 0
  fi
  {
    printf 'ID\tAGENT\tMACHINE\tTASK\tSTATE\tAGE\n'
    printf '%s\n' "$rows"
  } | column -t -s $'\t'
}

cmd_enter() {
  local id=${1:-} wid
  valid_id "$id" || {
    msg "invalid id"
    return 0
  }
  if wid=$(window_id "$id") && tmux select-window -t "$wid" 2>/dev/null; then
    return 0
  fi
  open_log "$id"
}

cmd_log() {
  local id=${1:-}
  valid_id "$id" || {
    msg "invalid id"
    return 0
  }
  open_log "$id"
}

cmd_kill() {
  local id=${1:-} wid
  valid_id "$id" || {
    msg "invalid id"
    return 0
  }
  if [[ $id == board ]]; then
    msg "board is this window, not an agent"
    return 0
  fi
  row_file "$id" >/dev/null || {
    msg "$id: no such row"
    return 0
  }
  if wid=$(window_id "$id"); then tmux kill-window -t "$wid" 2>/dev/null || true; fi
  agent-status set --id "$id" --state stopped
}

cmd_new() {
  local agent task
  read -r -p "agent (claude or opencode) [claude]: " agent || return 0
  agent=${agent:-claude}
  case $agent in
    claude | opencode) ;;
    *)
      msg "unknown agent: $agent"
      return 0
      ;;
  esac
  read -r -p "task: " task || return 0
  [[ -n $task ]] || return 0
  if ! command -v agent-run >/dev/null 2>&1; then
    msg "agent-run is not installed"
    return 0
  fi
  agent-run --agent "$agent" --task "$task" || msg "agent-run failed"
}

cmd_board() {
  local q rc=0
  command -v fzf >/dev/null 2>&1 || {
    echo "board: fzf not found" >&2
    exit 1
  }
  q=$(printf '%q' "$self")
  # The first line of the list is the header; with no rows it is the hint. --track keeps the
  # cursor on the same id when the list reloads.
  cmd_list | fzf \
    --layout=reverse --no-sort --header-lines=1 --track --id-nth=1 \
    --prompt='board> ' \
    --footer='Enter jump   Ctrl-L log   Ctrl-N new   Ctrl-X stop' \
    --bind "every(2):reload-sync($q _list)" \
    --bind "enter:execute($q _enter {1})" \
    --bind "ctrl-l:execute($q _log {1})" \
    --bind "ctrl-x:execute-silent($q _kill {1})+reload-sync($q _list)" \
    --bind "ctrl-n:execute($q _new)+reload-sync($q _list)" || rc=$?
  # 1 (no match) and 130 (Esc, Ctrl-C) are normal ways out.
  if ((rc == 1 || rc == 130)); then rc=0; fi
  return "$rc"
}

command=${1:-}
if (($# > 0)); then shift; fi
case $command in
  "") cmd_board ;;
  _list) cmd_list ;;
  _enter) cmd_enter "$@" ;;
  _log) cmd_log "$@" ;;
  _kill) cmd_kill "$@" ;;
  _new) cmd_new ;;
  *)
    echo "usage: board" >&2
    exit 2
    ;;
esac
