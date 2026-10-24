#!/usr/bin/env bash
# Tests for agent-status and agent-status-remote, run by checks.<system>.agent-status.
# Both commands must be on PATH.
set -u

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok() { echo "ok: $*"; }

# check NAME EXPECTED_RC CMD...: runs CMD, compares its exit code.
check_rc() {
  local name=$1 want=$2 rc
  shift 2
  "$@" >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq $want ]]; then ok "$name"; else fail "$name: exit $rc, want $want"; fi
}

check_eq() { # NAME GOT WANT
  if [[ $2 == "$3" ]]; then ok "$1"; else fail "$1: got '$2', want '$3'"; fi
}

tmp=$(mktemp -d)
export AGENT_STATUS_DIR=$tmp/agents
export HOME=$tmp/home
mkdir -p "$HOME"
row() { jq -c . "$AGENT_STATUS_DIR/$1.json"; }
field() { jq -r ".$2" "$AGENT_STATUS_DIR/$1.json"; }
files() { find "$AGENT_STATUS_DIR" -mindepth 1 | sort; }

# --- set creates a valid row
check_rc "set creates a row" 0 agent-status set --id a --agent claude --machine laptop \
  --task "fix the bug" --state working --pid 123 --window w1 --log /tmp/a.log
check_eq "row schema" "$(jq -c 'keys' "$AGENT_STATUS_DIR/a.json")" \
  '["agent","id","log","machine","pid","since","state","task","updated","window"]'
check_eq "row values" "$(jq -c '[.id,.agent,.machine,.task,.state,.pid,.window,.log]' "$AGENT_STATUS_DIR/a.json")" \
  '["a","claude","laptop","fix the bug","working",123,"w1","/tmp/a.log"]'
check_eq "times are numbers" "$(jq -r '[.since,.updated]|map(type)|join(",")' "$AGENT_STATUS_DIR/a.json")" "number,number"

# --- merge: state change moves since, other fields stay
since1=$(field a since)
updated1=$(field a updated)
sleep 1
check_rc "set --state only" 0 agent-status set --id a --state waiting
check_eq "merge keeps task" "$(field a task)" "fix the bug"
check_eq "merge keeps machine" "$(field a machine)" "laptop"
check_eq "merge keeps pid" "$(field a pid)" "123"
check_eq "state updated" "$(field a state)" "waiting"
since2=$(field a since)
[[ $since2 -gt $since1 ]] && ok "since moves on state change" || fail "since did not move ($since1 -> $since2)"

# --- same state keeps since, updated moves
sleep 1
check_rc "set same state" 0 agent-status set --id a --state waiting
check_eq "since kept for same state" "$(field a since)" "$since2"
[[ $(field a updated) -gt $updated1 ]] && ok "updated always moves" || fail "updated did not move"

# --- 20 parallel writers to one id
for i in $(seq 1 20); do
  agent-status set --id par --task "writer $i" --state working &
done
wait
jq -e 'type == "object" and .id == "par" and (.task | startswith("writer "))' \
  "$AGENT_STATUS_DIR/par.json" >/dev/null && ok "parallel writers leave valid JSON" \
  || fail "parallel writers: invalid row: $(cat "$AGENT_STATUS_DIR/par.json")"
leftover=$(files | grep -vE '/(\.lock|[a-z0-9.]+\.json)$' || true)
check_eq "no temp files left" "$leftover" ""

# --- hostile ids and oversized input write nothing
before=$(files)
check_rc "id ../x" 2 agent-status set --id ../x --state done
check_rc "id with space" 2 agent-status set --id "A B" --state done
check_rc "id uppercase" 2 agent-status set --id Abc --state done
check_rc "id leading dot" 2 agent-status set --id .hidden --state done
check_rc "id 65 chars" 2 agent-status set --id "$(printf 'a%.0s' $(seq 1 65))" --state done
check_rc "id empty" 2 agent-status set --id "" --state done
check_rc "missing id" 2 agent-status set --state done
check_rc "task 201 chars" 2 agent-status set --id t --task "$(printf 'x%.0s' $(seq 1 201))"
check_rc "task newline" 2 agent-status set --id t --task $'a\nb'
check_rc "task escape char" 2 agent-status set --id t --task $'a\033[31mb'
check_rc "bad state" 2 agent-status set --id t --state exploded
check_rc "bad pid" 2 agent-status set --id t --pid '1; rm'
check_rc "unknown flag" 2 agent-status set --id t --bogus x
check_rc "flag without value" 2 agent-status set --id t --task
check_rc "unknown command" 2 agent-status frobnicate
big=$(head -c 1000000 /dev/zero | tr '\0' a)
if agent-status set --id big --task "$big" >/dev/null 2>&1; then fail "1 MB task accepted"; else ok "1 MB task fails"; fi
check_eq "hostile input wrote nothing" "$(files)" "$before"
[[ ! -e $tmp/x.json && ! -e $tmp/x ]] && ok "no escape from the directory" || fail "file escaped the directory"

# multibyte text counts characters, not bytes
check_rc "150 multibyte chars accepted" 0 agent-status set --id mb --task "$(printf 'é%.0s' $(seq 1 150))"

# --- list
lst=$tmp/list
mkdir -p "$lst"
{
  export AGENT_STATUS_DIR=$lst
  : > "$lst/empty.json"
  printf '{"id":"trunc","ag' > "$lst/trunc.json"
  printf 'not json at all' > "$lst/junk.json"
  agent-status set --id good --agent claude --machine devbox --task "do it" --state done
  out=$(agent-status list); rc=$?
  check_eq "list exit with broken files" "$rc" "0"
  check_eq "list prints a line per file" "$(printf '%s\n' "$out" | wc -l)" "4"
  grep -qP '^empty\.json\t\?\t\?\t\?\t\?\t\?$' <<<"$out" && ok "empty file row" || fail "empty file row: $out"
  grep -qP '^trunc\.json\t\?\t\?\t\?\t\?\t\?$' <<<"$out" && ok "truncated file row" || fail "truncated row: $out"
  grep -qP '^junk\.json\t\?\t\?\t\?\t\?\t\?$' <<<"$out" && ok "non-JSON file row" || fail "junk row: $out"
  grep -qP '^good\tclaude\tdevbox\tdo it\tdone\t[0-9]+[smhd]$' <<<"$out" && ok "good row columns" || fail "good row: $out"
  check_eq "unreadable rows sort last" "$(printf '%s\n' "$out" | head -1 | cut -f1)" "good"
  agent-status list --json | jq -e 'type == "array" and length == 1 and .[0].id == "good"' >/dev/null \
    && ok "list --json skips unreadable files" || fail "list --json"
}

export AGENT_STATUS_DIR=$tmp/agents
out=$(AGENT_STATUS_DIR=$tmp/missing agent-status list); rc=$?
check_eq "list missing dir exit" "$rc" "0"
check_eq "list missing dir output" "$out" ""
check_eq "list --json missing dir" "$(AGENT_STATUS_DIR=$tmp/missing agent-status list --json)" "[]"
[[ ! -e $tmp/missing ]] && ok "list does not create the directory" || fail "list created the directory"
check_rc "reconcile missing dir" 0 env AGENT_STATUS_DIR="$tmp/missing" agent-status reconcile

# --- list order: most recently updated first
ord=$tmp/order
{
  export AGENT_STATUS_DIR=$ord
  agent-status set --id first --state done
  sleep 1
  agent-status set --id second --state done
  check_eq "list sorted by updated desc" "$(agent-status list | cut -f1 | paste -sd,)" "second,first"
  agent-status rm first
  check_eq "rm removes the row" "$(agent-status list | cut -f1 | paste -sd,)" "second"
  agent-status rm first
  check_rc "rm of a missing row" 0 agent-status rm first
  check_rc "rm hostile id" 2 agent-status rm ../x
}

# --- reconcile
rec=$tmp/reconcile
{
  export AGENT_STATUS_DIR=$rec
  me=$(cat /proc/sys/kernel/hostname)
  sleep 0 & dead=$!
  wait "$dead"
  sleep 30 & live=$!
  agent-status set --id dead --machine "$me" --state working --pid "$dead"
  agent-status set --id deadwait --machine "$me" --state waiting --pid "$dead"
  agent-status set --id alive --machine "$me" --state working --pid "$live"
  agent-status set --id other --machine elsewhere --state working --pid "$dead"
  agent-status set --id finished --machine "$me" --state done --pid "$dead"
  agent-status set --id nopid --machine "$me" --state working
  agent-status reconcile; rc=$?
  kill "$live"
  check_eq "reconcile exit" "$rc" "0"
  g() { jq -r .state "$rec/$1.json"; }
  check_eq "dead working -> lost" "$(g dead)" "lost"
  check_eq "dead waiting -> lost" "$(g deadwait)" "lost"
  check_eq "live pid untouched" "$(g alive)" "working"
  check_eq "other machine untouched" "$(g other)" "working"
  check_eq "finished untouched" "$(g finished)" "done"
  check_eq "no pid untouched" "$(g nopid)" "working"
}

# --- agent-status-remote
rm -f /tmp/x
remote() { SSH_ORIGINAL_COMMAND=$1 agent-status-remote; }
# agent-status-remote drops AGENT_STATUS_DIR, so its rows go to the default directory.
rdir=$HOME/.local/state/agents
export AGENT_STATUS_DIR=$tmp/not-used-by-remote

# Every payload below carries --machine laptop, so a rejection comes from the parser or from
# agent-status, not from the missing machine name.
M="--machine laptop"
check_rc "remote: injection with ;" 2 remote "agent-status set $M --id a --state done; touch /tmp/x"
check_rc "remote: injection with &&" 2 remote "agent-status set $M --id a --state done && touch /tmp/x"
check_rc "remote: injection with |" 2 remote "agent-status set $M --id a --state done | touch /tmp/x"
check_rc "remote: injection with backtick" 2 remote "agent-status set $M --id a --task \`touch /tmp/x\`"
check_rc "remote: injection with \$()" 2 remote "agent-status set $M --id a --task \$(touch /tmp/x)"
check_rc "remote: redirect" 2 remote "agent-status set $M --id a --state done > /tmp/x"
check_rc "remote: glob" 2 remote "agent-status set $M --id a --task /tmp/*"
check_rc "remote: double quotes" 2 remote "agent-status set $M --id a --task \"x\""
check_rc "remote: rm" 2 remote 'agent-status rm a'
check_rc "remote: list" 2 remote 'agent-status list'
check_rc "remote: reconcile" 2 remote 'agent-status reconcile'
check_rc "remote: \$(id)" 2 remote '$(id)'
check_rc "remote: other command" 2 remote 'touch /tmp/x'
check_rc "remote: embedded newline" 2 remote $'agent-status set --machine laptop --id a --state done\ntouch /tmp/x'
check_rc "remote: carriage return" 2 remote $'agent-status set --machine laptop --id a --state done\rtouch /tmp/x'
check_rc "remote: tab" 2 remote $'agent-status set\t--machine laptop --id a'
check_rc "remote: newline inside quotes" 2 remote $'agent-status set --machine laptop --id a --task \'x\ny\''
check_rc "remote: unterminated quote" 2 remote "agent-status set $M --id a --task 'x"
check_rc "remote: empty command" 2 remote ''
check_rc "remote: no command" 2 env -u SSH_ORIGINAL_COMMAND agent-status-remote
check_rc "remote: bare agent-status" 2 remote 'agent-status'
check_rc "remote: agent-status set with no flags" 2 remote 'agent-status set'
check_rc "remote: path-qualified binary" 2 remote "/usr/bin/agent-status set $M --id a --state done"
check_rc "remote: oversized command" 2 remote "agent-status set $M --id a --task '$(printf 'x%.0s' $(seq 1 5000))'"
check_rc "remote: bad id is rejected by agent-status" 2 remote "agent-status set $M --id ../x --state done"
[[ ! -e /tmp/x ]] && ok "remote: nothing was executed" || fail "remote: /tmp/x exists"
check_eq "remote: rejected input wrote nothing" "$(find "$rdir" -name '*.json' 2>/dev/null | wc -l)" "0"

check_rc "remote: valid set" 0 remote "agent-status set --id r1 --agent claude --machine laptop --state working --task 'fix it'"
check_eq "remote: row written" "$(jq -r '[.id,.machine,.state,.task]|join("|")' "$rdir/r1.json")" "r1|laptop|working|fix it"
check_rc "remote: shell metacharacters in quotes stay data" 0 \
  remote "agent-status set $M --id r2 --task '\$(touch /tmp/x); \`id\` | a > b'"
check_eq "remote: quoted data is literal" "$(jq -r .task "$rdir/r2.json")" '$(touch /tmp/x); `id` | a > b'
check_rc "remote: escaped quote idiom" 0 remote "agent-status set $M --id r3 --task 'it'\\''s fine'"
check_eq "remote: quote idiom literal" "$(jq -r .task "$rdir/r3.json")" "it's fine"
check_rc "remote: concatenated segments" 0 remote "agent-status set $M --id r4 --task 'a'b'c d'"
check_eq "remote: segments joined" "$(jq -r .task "$rdir/r4.json")" "abc d"
[[ ! -e /tmp/x ]] && ok "remote: quoted data never executed" || fail "remote: /tmp/x exists after quoted data"

# --- agent-status-remote: the machine name is required and is never the devbox's own
me=$(cat /proc/sys/kernel/hostname)
before=$(find "$rdir" -name '*.json' | sort)
check_rc "remote: missing --machine" 2 remote "agent-status set --id m1 --state done"
check_rc "remote: --machine devbox" 2 remote "agent-status set --id m1 --machine devbox --state done"
check_rc "remote: --machine DevBox (case)" 2 remote "agent-status set --id m1 --machine DevBox --state done"
check_rc "remote: --machine own hostname" 2 remote "agent-status set --id m1 --machine '$me' --state done"
check_rc "remote: --machine own hostname upper" 2 remote "agent-status set --id m1 --machine '${me^^}' --state done"
check_rc "remote: --machine localhost" 2 remote "agent-status set --id m1 --machine localhost --state done"
check_rc "remote: empty --machine" 2 remote "agent-status set --id m1 --machine '' --state done"
check_rc "remote: --machine with space" 2 remote "agent-status set --id m1 --machine 'a b' --state done"
check_rc "remote: --machine twice, devbox last" 2 remote "agent-status set --id m1 --machine thinkpad --machine devbox --state done"
check_rc "remote: --machine twice, devbox first" 2 remote "agent-status set --id m1 --machine devbox --machine thinkpad --state done"
check_rc "remote: --machine only as a value" 2 remote "agent-status set --id m1 --task --machine --state done"
check_rc "remote: odd number of flag words" 2 remote "agent-status set --machine thinkpad --id m1 --state"
check_eq "remote: machine rejections wrote nothing" "$(find "$rdir" -name '*.json' | sort)" "$before"
check_rc "remote: --machine thinkpad accepted" 0 remote "agent-status set --id m2 --machine thinkpad --state working"
check_eq "remote: machine recorded" "$(jq -r .machine "$rdir/m2.json")" "thinkpad"

# AGENT_STATUS_DIR from the caller is dropped: the row lands in the default directory.
redirect=$tmp/redirect
default=$rdir
check_rc "remote: AGENT_STATUS_DIR set by caller" 0 \
  env AGENT_STATUS_DIR="$redirect" SSH_ORIGINAL_COMMAND="agent-status set --id e1 --machine thinkpad --state done" agent-status-remote
[[ -f $default/e1.json ]] && ok "remote: row went to the default dir" || fail "remote: no row in $default"
[[ ! -e $redirect ]] && ok "remote: AGENT_STATUS_DIR ignored" || fail "remote: wrote to the caller's AGENT_STATUS_DIR"

echo
if (( fails > 0 )); then echo "$fails test(s) failed" >&2; exit 1; fi
echo "all tests passed"
