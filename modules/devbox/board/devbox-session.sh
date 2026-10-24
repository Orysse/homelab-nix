# shellcheck shell=bash
# devbox-session: attach the tmux session `devbox`, creating it first when it does not exist.
# Window 0 is named `board` and runs `board`. Run by the zsh login hook (guest.nix) as
# `exec devbox-session`, so on a failure it hands the terminal to a plain shell instead of
# closing the login. Without a terminal it only makes sure the session exists.

session=devbox

fallback() {
  echo "devbox-session: $*" >&2
  # A non-login shell: the login hook does not run again.
  if [[ -t 0 && -t 1 ]]; then exec "${SHELL:-/bin/sh}"; fi
  exit 1
}

command -v tmux >/dev/null 2>&1 || fallback "tmux not found"
board_bin=$(command -v board) || fallback "board not found"

if ! tmux has-session -t "=$session" 2>/dev/null; then
  # Two logins at once: the loser of new-session finds the session made by the winner.
  tmux new-session -d -s "$session" -n board "$(printf '%q' "$board_bin")" 2>/dev/null ||
    tmux has-session -t "=$session" 2>/dev/null ||
    fallback "cannot create tmux session $session"
fi

if [[ -t 0 && -t 1 ]]; then
  tmux attach-session -t "=$session" || fallback "cannot attach tmux session $session"
fi
