# shellcheck shell=bash
# agent-status-remote: forced command (command="agent-status-remote" in authorized_keys) for
# agents on other machines. It reads SSH_ORIGINAL_COMMAND and accepts exactly
#   agent-status set <flags>
# where each word is plain characters or single-quoted text ('it'\''s' is the usual way to
# send an apostrophe). No shell ever sees the text: it is split by this script into an array
# and handed to agent-status with exec. Anything else exits 2.
# agent-status itself checks the flags and values. This script puts `--remote` in front of them
# (a caller who sends it is rejected): agent-status then refuses to overwrite a row of this machine.
#
# --machine NAME is required (once) and is never the devbox's own name (its hostname, `devbox`,
# `localhost`): every remote row carries its origin and cannot pass for a local one, which
# `agent-status reconcile` would mark `lost` (it checks the pid of rows of its own machine).
# AGENT_STATUS_DIR and other variables that could redirect the commands are dropped, so a row
# always goes to the default directory of `abel`.
#
# Client call. ssh joins its arguments with spaces and the remote login shell does not see them
# (the forced command ignores it): build one string, with single quotes around the free text.
# The parser knows no other quoting, so an apostrophe in the text is sent as '\'' :
#   task="fix the bug in o'brien's parser"
#   ssh -i ~/.ssh/devbox-status -o IdentitiesOnly=yes abel@devbox \
#     "agent-status set --id my-agent --machine $(hostname) --agent claude --state working --task '${task//\'/\'\\\'\'}'"
# --id is 1-64 characters of [a-z0-9._-] (no leading dot); --state is one of the states of agent-status.

export LC_ALL=C.UTF-8
unset AGENT_STATUS_DIR BASH_ENV ENV CDPATH LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LOCALDOMAIN HOSTALIASES

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

# The flags after `set` come in pairs, as agent-status reads them: look for --machine in the
# flag positions only (a value may be the text `--machine`), and take every occurrence.
flags=("${words[@]:2}")
((${#flags[@]} % 2 == 0)) || reject "flags come with a value each"
machine=""
machines=0
for ((i = 0; i < ${#flags[@]}; i += 2)); do
  # --remote is ours to add below; from the caller it is an unknown flag.
  [[ ${flags[i]} != "--remote" ]] || reject "unknown option --remote"
  if [[ ${flags[i]} == "--machine" ]]; then
    machine=${flags[i + 1]}
    machines=$((machines + 1))
  fi
done
((machines == 1)) || reject "--machine NAME is required, once"
[[ $machine =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || reject "--machine: letters, digits, . _ - only"
own=$(<"/proc/sys/kernel/hostname")
own=${own,,}
name=${machine,,}
for own_name in "$own" "${own%%.*}" devbox localhost; do
  [[ $name != "$own_name" && ${name%%.*} != "$own_name" ]] || reject "--machine must name the calling machine, not this one"
done

# --remote: agent-status then refuses to change a row of this machine (a local agent's row).
exec agent-status set --remote "${words[@]:2}"
