# shellcheck shell=bash
# agent-hook EVENT: Claude Code hook (registered in the managed settings, see agent-board.nix).
# Reads the hook JSON on stdin (session_id, cwd) and updates the row of the session:
#   SessionStart -> working, UserPromptSubmit -> working, Notification -> waiting,
#   Stop -> waiting, SessionEnd -> done.
# The row id is claude-<first 8 characters of session_id>, or $AGENT_RUN_ID when agent-run started
# this session (its row exists already, and a second one would show the agent twice). A row that is
# `stopped` (Ctrl-X on the board) is not written again, so SessionEnd cannot turn it into `done`.
# It never blocks and never fails the agent: it prints nothing (the stdout of some hook events is
# added to the conversation), reads at most 1 MiB of stdin, bounds agent-status with a timeout and
# always exits 0. Anything it cannot make sense of is ignored.

export LC_ALL=C.UTF-8

hook() {
  local event=${1:-} state input session cwd id task row
  # A scheduled job (job-triage) has its own row and sets this for its claude: no second row.
  if [[ ${AGENT_HOOK_DISABLE:-} == 1 ]]; then return 0; fi
  case $event in
    SessionStart | UserPromptSubmit) state=working ;;
    Notification | Stop) state=waiting ;;
    SessionEnd) state="done" ;;
    *) return 0 ;;
  esac
  input=$(head -c 1048576 2>/dev/null) || return 0
  session=$(jq -r 'if type == "object" and (.session_id | type) == "string" then .session_id else empty end' <<<"$input" 2>/dev/null) || return 0
  [[ $session =~ ^[A-Za-z0-9][A-Za-z0-9-]{7,}$ ]] || return 0
  session=${session,,}
  id=claude-${session:0:8}
  if [[ ${AGENT_RUN_ID:-} =~ ^claude-[0-9]{1,6}$ ]]; then
    # A row of agent-run: it keeps its task, window and log. Ctrl-X on the board marks it `stopped`
    # before it kills the window, and this hook (SessionEnd, as the session dies) must not undo that.
    row=$(head -c 65536 "${AGENT_STATUS_DIR:-$HOME/.local/state/agents}/$AGENT_RUN_ID.json" 2>/dev/null |
      jq -r 'if type == "object" and (.state | type) == "string" then .state else empty end' 2>/dev/null) || row=""
    if [[ $row == stopped ]]; then return 0; fi
    timeout 4 agent-status set --id "$AGENT_RUN_ID" --state "$state" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ $event == SessionStart ]]; then
    cwd=$(jq -r 'if (.cwd | type) == "string" then .cwd else empty end' <<<"$input" 2>/dev/null) || cwd=""
    cwd=${cwd//[[:cntrl:]]/ }
    task="claude in ${cwd:-?}"
    timeout 4 agent-status set --id "$id" --agent claude --machine devbox --task "${task:0:200}" --state "$state" >/dev/null 2>&1 || true
  else
    timeout 4 agent-status set --id "$id" --agent claude --machine devbox --state "$state" >/dev/null 2>&1 || true
  fi
}

hook "$@" || true
exit 0
