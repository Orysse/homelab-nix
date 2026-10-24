# shellcheck shell=bash
# agent-status-remote: forced command (command="agent-status-remote" in authorized_keys) for
# agents on other machines. It reads SSH_ORIGINAL_COMMAND and accepts exactly
#   agent-status set <flags>
# where each word is plain characters or single-quoted text ('it'\''s' is the usual way to
# send an apostrophe). No shell ever sees the text: it is split by this script into an array
# and handed to agent-status with exec. Anything else exits 2.
# agent-status itself checks the flags and values.

export LC_ALL=C.UTF-8

max_command=4096
max_words=40

reject() {
  echo "agent-status-remote: rejected: $*" >&2
  exit 2
}

cmd=${SSH_ORIGINAL_COMMAND-}
[[ -n $cmd ]] || reject "no command"
((${#cmd} <= max_command)) || reject "command too long"
[[ $cmd != *[[:cntrl:]]* ]] || reject "control characters"

words=()
word=""
inword=0
inquote=0
plain='[A-Za-z0-9._/:@%+=,-]'

for ((i = 0; i < ${#cmd}; i++)); do
  c=${cmd:i:1}
  if ((inquote)); then
    if [[ $c == "'" ]]; then inquote=0; else word+=$c; fi
  elif [[ $c == "'" ]]; then
    inquote=1
    inword=1
  elif [[ $c == "\\" ]]; then
    # only the escaped apostrophe outside quotes
    [[ ${cmd:i+1:1} == "'" ]] || reject "backslash"
    word+="'"
    inword=1
    i=$((i + 1))
  elif [[ $c == " " ]]; then
    if ((inword)); then
      words+=("$word")
      word=""
      inword=0
    fi
  elif [[ $c =~ ^$plain$ ]]; then
    word+=$c
    inword=1
  else
    reject "character not allowed outside quotes"
  fi
done
((!inquote)) || reject "unterminated quote"
if ((inword)); then words+=("$word"); fi

((${#words[@]} >= 3)) || reject "want: agent-status set <flags>"
((${#words[@]} <= max_words)) || reject "too many words"
[[ ${words[0]} == "agent-status" && ${words[1]} == "set" ]] || reject "only 'agent-status set' is allowed"

exec agent-status "${words[@]:1}"
