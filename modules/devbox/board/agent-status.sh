# shellcheck shell=bash
# agent-status: one JSON row per agent in $AGENT_STATUS_DIR (default ~/.local/state/agents).
#   agent-status set --id ID [--agent A] [--machine M] [--task T] [--state S] [--pid N] [--window W] [--log PATH]
#                    [--remote]
#     --remote (no value) is added by agent-status-remote only: the set is then refused (exit 2) when
#     the existing row of ID belongs to this machine, so a remote key cannot take over a local row.
#   agent-status list [--json]
#   agent-status rm ID
#   agent-status reconcile
# Writers take an flock on <dir>/.lock and replace the row by temp file + rename, so readers
# never see a half-written row. Every value is checked first and JSON is built by jq only.
# Exit codes: 2 for a rejected argument, 1 for any other failure.

# Character counts and [[:cntrl:]] must follow UTF-8, not bytes.
export LC_ALL=C.UTF-8

dir=${AGENT_STATUS_DIR:-$HOME/.local/state/agents}
max_text=200
max_log=1000
max_file=65536 # a row is far smaller; anything bigger is not a row
states=" scheduled working waiting done failed skipped lost stopped "
tmp=""

die() {
  echo "agent-status: $*" >&2
  exit 2
}

trap '[[ -z $tmp ]] || rm -f "$tmp"' EXIT

# check_text NAME VALUE MAX
check_text() {
  local name=$1 value=$2 max=$3
  ((${#value} <= max)) || die "$name is longer than $max characters"
  [[ $value != *[[:cntrl:]]* ]] || die "$name contains control characters"
}

check_id() {
  [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || die "invalid id (want ^[a-z0-9][a-z0-9._-]{0,63}\$)"
}

lock() {
  mkdir -p "$dir"
  exec 9>"$dir/.lock"
  flock -w 10 9 || {
    echo "agent-status: cannot lock $dir" >&2
    exit 1
  }
}

# read_row FILE: prints the row as compact JSON, or nothing if it is not a JSON object.
read_row() {
  head -c "$max_file" "$1" 2>/dev/null | jq -ec 'select(type == "object")' 2>/dev/null || true
}

# write_row ID PATCH_JSON: merge PATCH into the existing row of ID. Caller holds the lock.
write_row() {
  local id=$1 patch=$2 now old machine
  now=$(date +%s)
  machine=$(<"/proc/sys/kernel/hostname")
  old=$(read_row "$dir/$id.json")
  [[ -n $old ]] || old='{}'
  tmp=$(mktemp "$dir/.$id.XXXXXX")
  jq -nc --argjson old "$old" --argjson patch "$patch" --argjson now "$now" \
    --arg id "$id" --arg machine "$machine" '
    ({agent: "", machine: $machine, task: "", state: "working", pid: null, window: "", log: ""}
      + $old + $patch) as $r
    | $r + {id: $id, updated: $now,
            since: (if $old.state == $r.state and ($old.since | type) == "number"
                    then $old.since else $now end)}
    | {id, agent, machine, task, state, since, updated, pid, window, log}' >"$tmp"
  mv -f "$tmp" "$dir/$id.json"
  tmp=""
}

# is_local_machine NAME: true for this host's name (any case, or its first DNS label) and `devbox`.
is_local_machine() {
  local name=${1,,} own own_name
  own=$(<"/proc/sys/kernel/hostname")
  own=${own,,}
  for own_name in "$own" "${own%%.*}" devbox; do
    if [[ $name == "$own_name" || ${name%%.*} == "$own_name" ]]; then return 0; fi
  done
  return 1
}

# refuse_local_row ID: a --remote set may not touch an existing row of this machine (a row with no
# machine field counts as one: write_row would fill in this host's name). Caller holds the lock.
refuse_local_row() {
  local old machine
  old=$(read_row "$dir/$1.json")
  [[ -n $old ]] || return 0
  machine=$(jq -r '.machine | if type == "string" then . else "" end' <<<"$old")
  if [[ -z $machine ]] || is_local_machine "$machine"; then
    die "refused: $1 is a row of this machine"
  fi
}

cmd_set() {
  local id="" patch='{}' key value remote=0
  while (($# > 0)); do
    # --remote has no value: agent-status-remote (and nothing else) adds it, after its own checks.
    if [[ $1 == --remote ]]; then
      remote=1
      shift
      continue
    fi
    (($# >= 2)) || die "$1 needs a value"
    key=${1#--}
    value=$2
    case $1 in
      --id)
        check_id "$value"
        id=$value
        ;;
      --agent | --machine | --task | --window)
        check_text "$key" "$value" "$max_text"
        patch=$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' <<<"$patch")
        ;;
      --log)
        check_text log "$value" "$max_log"
        patch=$(jq -c --arg v "$value" '. + {log: $v}' <<<"$patch")
        ;;
      --state)
        [[ $states == *" $value "* && -n $value ]] || die "invalid state (want:$states)"
        patch=$(jq -c --arg v "$value" '. + {state: $v}' <<<"$patch")
        ;;
      --pid)
        [[ $value =~ ^[0-9]{1,10}$ ]] || die "invalid pid"
        patch=$(jq -c --argjson v "$((10#$value))" '. + {pid: $v}' <<<"$patch")
        ;;
      *) die "unknown option $1" ;;
    esac
    shift 2
  done
  [[ -n $id ]] || die "--id is required"
  lock
  if ((remote)); then refuse_local_row "$id"; fi
  write_row "$id" "$patch"
}

cmd_rm() {
  (($# == 1)) || die "usage: agent-status rm ID"
  check_id "$1"
  [[ -d $dir ]] || return 0
  lock
  rm -f "$dir/$1.json"
}

# list_lines: "<sort key>\t<display line>" per file, unreadable files get key -1.
list_lines() {
  local f row now name
  now=$(date +%s)
  for f in "$dir"/*.json; do
    [[ -e $f ]] || continue
    row=$(head -c "$max_file" "$f" 2>/dev/null | jq -er --argjson now "$now" '
      def clean: tostring | gsub("[\\p{Cc}]"; " ") | if . == "" then "-" else . end;
      def age: ($now - .) as $d
        | if $d < 60 then "\([$d, 0] | max | floor)s"
          elif $d < 3600 then "\($d / 60 | floor)m"
          elif $d < 86400 then "\($d / 3600 | floor)h"
          else "\($d / 86400 | floor)d" end;
      if type != "object" then error("not a row") else . end
      | (.updated | if type == "number" then ([., 0] | max | [., 99999999999] | min | floor) else 0 end) as $key
      | "\($key)\t" + ([(.id // "?"), (.agent // "?"), (.machine // "?"), (.task // "?"), (.state // "?"),
                        (.updated | if type == "number" then age else "?" end)]
                       | map(clean) | join("\t"))' 2>/dev/null) || row=""
    if [[ -n $row ]]; then
      printf '%s\n' "$row"
    else
      name=${f##*/}
      printf -- '-1\t%s\t?\t?\t?\t?\t?\n' "${name//[^A-Za-z0-9._-]/?}"
    fi
  done
}

cmd_list() {
  local f
  case ${1:-} in
    "")
      list_lines | sort -t $'\t' -k1,1nr -s | cut -f2-
      ;;
    --json)
      (($# == 1)) || die "usage: agent-status list [--json]"
      for f in "$dir"/*.json; do
        [[ -e $f ]] || continue
        read_row "$f"
      done | jq -s 'sort_by(.updated | if type == "number" then . else 0 end) | reverse'
      ;;
    *) die "usage: agent-status list [--json]" ;;
  esac
}

# reconcile: working/waiting rows of this machine whose pid is gone become "lost".
cmd_reconcile() {
  local f id pid machine
  [[ -d $dir ]] || return 0
  lock
  machine=$(<"/proc/sys/kernel/hostname")
  for f in "$dir"/*.json; do
    [[ -e $f ]] || continue
    id=$(basename "$f" .json)
    [[ $id =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]] || continue
    pid=$(read_row "$f" | jq -r --arg m "$machine" '
      select(.machine == $m and (.state == "working" or .state == "waiting") and (.pid | type) == "number")
      | .pid | floor' 2>/dev/null || true)
    [[ $pid =~ ^[0-9]+$ ]] || continue
    [[ -d /proc/$pid ]] || write_row "$id" '{"state": "lost"}'
  done
}

command=${1:-}
if (($# > 0)); then shift; fi
case $command in
  set) cmd_set "$@" ;;
  list) cmd_list "$@" ;;
  rm) cmd_rm "$@" ;;
  reconcile)
    (($# == 0)) || die "usage: agent-status reconcile"
    cmd_reconcile
    ;;
  *) die "usage: agent-status set|list|rm|reconcile ..." ;;
esac
