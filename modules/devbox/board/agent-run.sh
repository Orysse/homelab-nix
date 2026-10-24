# shellcheck shell=bash
# agent-run --agent claude|opencode --task TEXT [--dir DIR]
# Starts an agent in a new window of the tmux session `devbox` and keeps its row on the board:
#   - the id is <agent>-<n>, the smallest n without a row or log, and the window is named by the id;
#   - the log is <status dir>/<id>.log, which is where the board looks for it;
#   - the row is `working` (with window, pid and log) while the agent runs, then `done` (exit 0)
#     or `failed`.
# The agent runs under `script`, not `tee`: claude and opencode are full-screen programs and need
# a terminal on stdout, a pipe would turn them into batch tools. `script` keeps the terminal and
# writes the same bytes to the log (with their escape codes), and `-e` returns the agent's status.
# The task reaches the agent through the environment, never through a shell string.
# Exit codes: 2 for a rejected argument, 1 for any other failure.

export LC_ALL=C.UTF-8

dir=${AGENT_STATUS_DIR:-$HOME/.local/state/agents}
session=devbox
max_text=200

die() {
  echo "agent-run: $*" >&2
  exit "${2:-2}"
}

# _wrap ID AGENT: runs inside the tmux window, started by cmd_start. cwd is the agent's directory.
cmd_wrap() {
  local id=$1 agent=$2 log final rc=0
  log=$dir/$id.log
  export AGENT_RUN_ID=$id # agent-hook updates this row instead of making a second one
  agent-status set --id "$id" --state working --pid "$$" --window "$id" --log "$log" || true
  # The single quotes are on purpose: script's shell expands $AGENT_RUN_TASK, this one does not.
  # shellcheck disable=SC2016
  case $agent in
    claude) script -qefa -c 'exec claude "$AGENT_RUN_TASK"' "$log" || rc=$? ;;
    opencode) script -qefa -c 'exec opencode "--prompt=$AGENT_RUN_TASK"' "$log" || rc=$? ;;
  esac
  if ((rc == 0)); then final="done"; else final=failed; fi
  agent-status set --id "$id" --state "$final" || true
  exit "$rc"
}

cmd_start() {
  local agent="" task="" workdir="" key id n log self board_bin
  while (($# > 0)); do
    (($# >= 2)) || die "$1 needs a value"
    key=$1
    case $key in
      --agent) agent=$2 ;;
      --task) task=$2 ;;
      --dir) workdir=$2 ;;
      *) die "unknown option $key" ;;
    esac
    shift 2
  done

  case $agent in
    claude | opencode) ;;
    *) die "--agent must be claude or opencode" ;;
  esac
  [[ -n $task ]] || die "--task is required"
  ((${#task} <= max_text)) || die "task is longer than $max_text characters"
  [[ $task != *[[:cntrl:]]* ]] || die "task contains control characters"
  [[ $task != -* ]] || die "task must not start with a dash"
  workdir=$(cd -- "${workdir:-$HOME/work}" 2>/dev/null && pwd) || die "directory not found: ${workdir:-$HOME/work}"
  command -v tmux >/dev/null 2>&1 || die "tmux not found" 1
  command -v "$agent" >/dev/null 2>&1 || die "$agent not found" 1
  self=$(readlink -f "$0")

  # One lock for the whole allocation: the id is free, the row exists, the window exists. Two calls
  # at once cannot get the same n, and agent-status takes its own lock (a different file).
  mkdir -p "$dir"
  exec 9>"$dir/.alloc.lock"
  flock -w 10 9 || die "cannot lock $dir" 1
  n=1
  while [[ -e $dir/$agent-$n.json || -e $dir/$agent-$n.log ]]; do n=$((n + 1)); done
  id=$agent-$n
  log=$dir/$id.log
  (umask 077 && : >"$log") || die "cannot create $log" 1
  # `scheduled` until the window runs: the wrapper then sets `working` together with its pid.
  agent-status set --id "$id" --agent "$agent" --task "$task" --state scheduled --window "$id" --log "$log" || {
    rm -f "$log"
    die "cannot write the row of $id" 1
  }

  # Every tmux call closes fd 9: the tmux server must not inherit the lock.
  local -a env_args=(-e "AGENT_RUN_TASK=$task" -e "AGENT_STATUS_DIR=$dir" -e "PATH=$PATH")
  local wrap_cmd
  wrap_cmd="exec $(printf '%q %q %q %q' "$self" _wrap "$id" "$agent")"
  if ! tmux has-session -t "=$session" 9>&- 2>/dev/null; then
    # The first window is the board, as devbox-session makes it. Without a board, the agent is it.
    # Two calls at once: the loser of new-session finds the session made by the winner.
    if board_bin=$(command -v board); then
      tmux new-session -d -s "$session" -n board "$(printf '%q' "$board_bin")" 9>&- 2>/dev/null || true
    else
      tmux new-session -d -s "$session" -n "$id" -c "$workdir" "${env_args[@]}" "$wrap_cmd" 9>&- 2>/dev/null || true
    fi
  fi
  if ! tmux list-windows -t "=$session:" -F '#{window_name}' 9>&- 2>/dev/null | grep -qxF -- "$id"; then
    tmux new-window -d -t "=$session:" -n "$id" -c "$workdir" "${env_args[@]}" "$wrap_cmd" 9>&- ||
      {
        agent-status set --id "$id" --state failed || true
        die "cannot open a tmux window for $id" 1
      }
  fi
  echo "$id"
}

if [[ ${1:-} == _wrap ]]; then
  (($# == 3)) || die "usage: agent-run _wrap ID AGENT"
  cmd_wrap "$2" "$3"
fi
cmd_start "$@"
