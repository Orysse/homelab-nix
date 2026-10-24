#!/usr/bin/env bash
# Tests for devbox-secrets, the zsh loader of its env file and the git credential helper, run by
# checks.<system>.devbox-secrets.
# On PATH: devbox-secrets, git-credential-devbox, zsh, git, coreutils, grep, bash. `bao` is a stub
# at the front of PATH: it records its arguments and BAO_TOKEN/BAO_ADDR, prints a token for
# `login` and $tmp/val-<name> for `kv get`; $tmp/login-fail and $tmp/fail-<name> make it fail.
# $SNIPPET is the zsh file with the loader, $INIT the generated programs.zsh.interactiveShellInit
# text, $GITCONFIG the generated /etc/gitconfig of the guest.
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
  if grep -qE -- "$3" <<<"$2"; then fail "$1: found '$3' in: $2"; else ok "$1"; fi
}

tmp=$(mktemp -d)
export HOME=$tmp/home
export XDG_RUNTIME_DIR=$tmp/run
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
trap 'rm -rf "$tmp"' EXIT
unset BAO_TOKEN BAO_ADDR GITHUB_TOKEN DEEPSEEK_API_KEY OPENROUTER_API_KEY
env_file=$XDG_RUNTIME_DIR/devbox-env
token=hvs.CAESIFakeToken_0123-abc

# The sandbox has no /usr/bin/env: the stubs get the absolute path of bash as interpreter.
sh=$(command -v bash)
stubs=$tmp/stubs
mkdir -p "$stubs"
cat >"$stubs/bao" <<EOF
#!$sh
printf '%s\n' "\$*" >>"$tmp/bao-argv"
printf 'addr=%s token=%s\n' "\${BAO_ADDR-unset}" "\${BAO_TOKEN-unset}" >>"$tmp/bao-env"
case \$1 in
  login)
    [[ -e $tmp/login-fail ]] && { echo "Error authenticating: user cancelled" >&2; exit 1; }
    [[ -e $tmp/login-empty ]] && exit 0
    printf '%s' "$token"
    ;;
  kv)
    name=\${!#}
    name=\${name##*/}
    [[ -e $tmp/fail-\$name ]] && { echo "Error reading kv/apps/devbox/\$name: 503 sealed" >&2; exit 2; }
    cat "$tmp/val-\$name"
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$stubs/bao"
export PATH=$stubs:$PATH

setvals() { # DEEPSEEK OPENROUTER GITHUB
  printf '%s' "$1" >"$tmp/val-deepseek"
  printf '%s' "$2" >"$tmp/val-openrouter"
  printf '%s' "$3" >"$tmp/val-github"
}
reset() {
  rm -rf "$tmp"/bao-argv "$tmp"/bao-env "$tmp"/login-fail "$tmp"/login-empty "$tmp"/fail-* "$HOME/.vault-token" "$HOME/pwned" "$tmp/pwned"
  rm -rf "${XDG_RUNTIME_DIR:?}"/* "${XDG_RUNTIME_DIR:?}"/.[!.]*
  setvals sk-deep_1.2 sk-or-v1-abc ghp_ABCdef123
}
run_secrets() { out=$(devbox-secrets 2>&1); rc=$?; }
no_stray() { # NAME: only the env file (or nothing) is left in the runtime dir
  local left
  left=$(ls -A "$XDG_RUNTIME_DIR" | grep -vx 'devbox-env' || true)
  check_eq "$1: no temp file left" "$left" ""
}
good_content=$'DEEPSEEK_API_KEY=old-deep\nOPENROUTER_API_KEY=old-or\nGITHUB_TOKEN=old-gh'
seed_old() { printf '%s\n' "$good_content" >"$env_file"; chmod 600 "$env_file"; }

# --- success: all three lines, mode 0600, nothing else written
reset
run_secrets
check_eq "success: exit status" "$rc" "0"
check_eq "success: env file content" "$(cat "$env_file")" $'DEEPSEEK_API_KEY=sk-deep_1.2\nOPENROUTER_API_KEY=sk-or-v1-abc\nGITHUB_TOKEN=ghp_ABCdef123'
check_eq "success: env file mode" "$(stat -c %a "$env_file")" "600"
no_stray "success"
check_eq "success: no ~/.vault-token" "$([[ -e $HOME/.vault-token ]] && echo present || echo absent)" "absent"
check_eq "success: nothing else in HOME" "$(ls -A "$HOME")" ""
check_lacks "success: values not printed" "$out" 'sk-deep|sk-or-v1|ghp_|hvs\.'

# --- the bao calls: flags, mount, address, token only in the environment
argv=$(cat "$tmp/bao-argv")
check_eq "bao called 4 times (login + 3 reads)" "$(wc -l <"$tmp/bao-argv")" "4"
check_has "login: oidc method" "$(sed -n 1p "$tmp/bao-argv")" '^login .*-method=oidc'
check_has "login: auth mount sso/oidc" "$(sed -n 1p "$tmp/bao-argv")" '-path=sso/oidc'
check_has "login: role devbox" "$(sed -n 1p "$tmp/bao-argv")" 'role=devbox$'
check_has "login: -no-store" "$(sed -n 1p "$tmp/bao-argv")" '(^| )-no-store( |$)'
check_has "login: -token-only" "$(sed -n 1p "$tmp/bao-argv")" '(^| )-token-only( |$)'
for name in deepseek openrouter github; do
  check_has "read $name: kv get on mount kv/apps, field value" "$argv" "^kv get -mount=kv/apps -field=value devbox/$name\$"
done
check_lacks "token never in argv" "$argv" 'hvs\.'
check_eq "token reaches the three reads through BAO_TOKEN" "$(grep -c "token=$token\$" "$tmp/bao-env")" "3"
check_eq "login runs without a token" "$(sed -n 1p "$tmp/bao-env" | grep -c 'token=unset')" "1"
check_eq "BAO_ADDR is the cluster's OpenBao" "$(grep -c '^addr=https://bao.int.abe.lc ' "$tmp/bao-env")" "4"

# --- an inherited BAO_TOKEN or BAO_ADDR does not reach bao
reset
BAO_TOKEN=inherited BAO_ADDR=https://evil.example run_secrets
check_eq "inherited BAO_TOKEN/BAO_ADDR are replaced" "$(grep -c 'inherited\|evil' "$tmp/bao-env")" "0"

# --- a read fails (second one): existing file untouched, no temp file
reset
seed_old
touch "$tmp/fail-openrouter"
run_secrets
check_eq "read fails: non-zero" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
check_has "read fails: message mentions OpenBao" "$out" 'OpenBao'
check_eq "read fails: env file untouched" "$(cat "$env_file")" "$good_content"
check_eq "read fails: env file mode kept" "$(stat -c %a "$env_file")" "600"
no_stray "read fails"
check_eq "read fails: no ~/.vault-token" "$([[ -e $HOME/.vault-token ]] && echo present || echo absent)" "absent"

# --- a read fails and there was no file: still none
reset
touch "$tmp/fail-github"
run_secrets
check_eq "read fails, no old file: no env file" "$([[ -e $env_file ]] && echo present || echo absent)" "absent"
no_stray "read fails, no old file"

# --- login cancelled
reset
seed_old
touch "$tmp/login-fail"
run_secrets
check_eq "login cancelled: non-zero" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
check_has "login cancelled: message mentions OpenBao" "$out" 'OpenBao'
check_eq "login cancelled: env file untouched" "$(cat "$env_file")" "$good_content"
no_stray "login cancelled"
check_eq "login cancelled: no read attempted" "$(grep -c '^kv ' "$tmp/bao-argv")" "0"

# --- login succeeds but prints no token
reset
seed_old
touch "$tmp/login-empty"
run_secrets
check_eq "empty token: non-zero" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
check_has "empty token: message mentions OpenBao" "$out" 'OpenBao'
check_eq "empty token: env file untouched" "$(cat "$env_file")" "$good_content"
no_stray "empty token"

# --- values outside [A-Za-z0-9_.-]: the whole run fails, the key is named, the value is not
bad_value() { # NAME VALUE KEYVAR OPENBAO-NAME
  local label=$1 value=$2 key=$3 field=$4
  reset
  seed_old
  setvals sk-deep_1.2 sk-or-v1-abc ghp_ABCdef123
  printf '%s' "$value" >"$tmp/val-$field"
  run_secrets
  check_eq "bad value ($label): non-zero" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
  check_has "bad value ($label): names $key" "$out" "$key"
  check_has "bad value ($label): mentions OpenBao" "$out" 'OpenBao'
  check_lacks "bad value ($label): value not printed" "$out" 'secretpart'
  check_eq "bad value ($label): env file untouched" "$(cat "$env_file")" "$good_content"
  no_stray "bad value ($label)"
}
bad_value space "secretpart with space" DEEPSEEK_API_KEY deepseek
bad_value dollar 'secretpart$HOME' OPENROUTER_API_KEY openrouter
bad_value subst 'secretpart$(touch pwned)' GITHUB_TOKEN github
bad_value backtick 'secretpart`id`' GITHUB_TOKEN github
bad_value quote "secretpart'x" DEEPSEEK_API_KEY deepseek
bad_value newline $'secretpart\nEVIL=1' OPENROUTER_API_KEY openrouter
bad_value semicolon 'secretpart;x' GITHUB_TOKEN github
bad_value empty '' DEEPSEEK_API_KEY deepseek
check_eq "bad values: nothing executed" "$([[ -e $HOME/pwned || -e $tmp/pwned || -e pwned ]] && echo yes || echo no)" "no"

# --- XDG_RUNTIME_DIR unset, or not a directory: refuse before any bao call
reset
out=$(env -u XDG_RUNTIME_DIR devbox-secrets 2>&1); rc=$?
check_eq "XDG_RUNTIME_DIR unset: non-zero" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
check_has "XDG_RUNTIME_DIR unset: clear message" "$out" 'XDG_RUNTIME_DIR'
check_eq "XDG_RUNTIME_DIR unset: bao not called" "$([[ -e $tmp/bao-argv ]] && echo called || echo no)" "no"
out=$(XDG_RUNTIME_DIR=$tmp/nope devbox-secrets 2>&1); rc=$?
check_eq "XDG_RUNTIME_DIR missing: non-zero" "$([[ $rc -ne 0 ]] && echo yes)" "yes"
check_has "XDG_RUNTIME_DIR missing: clear message" "$out" 'XDG_RUNTIME_DIR'
check_eq "XDG_RUNTIME_DIR missing: bao not called" "$([[ -e $tmp/bao-argv ]] && echo called || echo no)" "no"

# --- an existing file with a looser mode is replaced by a 0600 file
reset
seed_old
chmod 644 "$env_file"
run_secrets
check_eq "replaces a 0644 file: mode 600 after" "$(stat -c %a "$env_file")" "600"

# ======================= zsh loader =======================
zrun() { # ENVFILE-CONTENT-ALREADY-IN-PLACE: prints the environment of a zsh that sourced the snippet
  env -i PATH="$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" zsh -c "source $SNIPPET; devbox-load-env; printenv"
}
want_set() { # NAME KEY VALUE
  check_eq "$1: $2 exported" "$(zrun | grep "^$2=" || true)" "$2=$3"
}
want_unset() { # NAME KEY
  check_eq "$1: $2 not exported" "$(zrun | grep "^$2=" || true)" ""
}

reset
printf '%s\n' 'DEEPSEEK_API_KEY=d.1' 'OPENROUTER_API_KEY=o-2' 'GITHUB_TOKEN=g_3' >"$env_file"
chmod 600 "$env_file"
want_set "good file" DEEPSEEK_API_KEY d.1
want_set "good file" OPENROUTER_API_KEY o-2
want_set "good file" GITHUB_TOKEN g_3

# Hostile content: command substitution, extra keys, quotes, export prefix, a second line for a key.
reset
{
  echo "DEEPSEEK_API_KEY=\$(touch $tmp/pwned)"
  echo "OPENROUTER_API_KEY=ok-1"
  echo "export GITHUB_TOKEN=exported"
  echo "GITHUB_TOKEN=first_wins"
  echo "GITHUB_TOKEN=second"
  echo "PATH=/evil"
  echo "LD_PRELOAD=/evil.so"
  echo "EVIL=1"
  echo "\`touch $tmp/pwned\`"
  echo "\$(touch $tmp/pwned)"
} >"$env_file"
chmod 600 "$env_file"
want_unset "hostile file" DEEPSEEK_API_KEY
want_set "hostile file" OPENROUTER_API_KEY ok-1
want_set "hostile file" GITHUB_TOKEN first_wins
want_unset "hostile file" EVIL
want_unset "hostile file" LD_PRELOAD
check_eq "hostile file: PATH unchanged" "$(zrun | grep '^PATH=' | head -1)" "PATH=$PATH"
check_eq "hostile file: nothing executed" "$([[ -e $tmp/pwned ]] && echo yes || echo no)" "no"

# A bad first line of a key leaves it unset: a later good line does not take over.
reset
printf '%s\n' 'GITHUB_TOKEN="quoted"' 'GITHUB_TOKEN=good' 'OPENROUTER_API_KEY=fine' >"$env_file"
chmod 600 "$env_file"
want_unset "bad first line" GITHUB_TOKEN
want_set "bad first line" OPENROUTER_API_KEY fine
# No trailing newline on the last line.
reset
printf 'GITHUB_TOKEN=last' >"$env_file"
chmod 600 "$env_file"
want_set "no trailing newline" GITHUB_TOKEN last

# Wrong modes, a symlink, a missing file: nothing is read.
for mode in 644 640 620 604 660 666 777; do
  reset
  printf '%s\n' 'GITHUB_TOKEN=g_3' >"$env_file"
  chmod "$mode" "$env_file"
  want_unset "mode $mode" GITHUB_TOKEN
done
reset
printf '%s\n' 'GITHUB_TOKEN=g_3' >"$tmp/real-env"
chmod 600 "$tmp/real-env"
ln -s "$tmp/real-env" "$env_file"
want_unset "symlink to a 0600 file" GITHUB_TOKEN
reset
want_unset "missing file" GITHUB_TOKEN
check_eq "missing file: loader silent" "$(env -i PATH="$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" zsh -c "source $SNIPPET; devbox-load-env" 2>&1)" ""
check_eq "XDG_RUNTIME_DIR unset: loader silent" "$(env -i PATH="$PATH" HOME="$HOME" zsh -c "source $SNIPPET; devbox-load-env" 2>&1)" ""
reset
mkdir "$env_file"
chmod 700 "$env_file"
check_eq "directory in place of the file: loader silent" "$(env -i PATH="$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" zsh -c "source $SNIPPET; devbox-load-env" 2>&1)" ""
rmdir "$env_file"

# The generated interactiveShellInit loads the file by itself (an interactive zsh reads it).
reset
printf '%s\n' 'GITHUB_TOKEN=g_init' >"$env_file"
chmod 600 "$env_file"
check_eq "interactiveShellInit exports from the file" \
  "$(env -i PATH="$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" zsh -c "source $INIT; printenv GITHUB_TOKEN")" "g_init"

# `devbox-secrets` in the shell reloads the file afterwards, and not when it failed.
reset
mkdir "$tmp/wrap"
cat >"$tmp/wrap/devbox-secrets" <<EOF
#!$sh
[[ -e $tmp/wrap-fail ]] && exit 1
printf '%s\n' 'GITHUB_TOKEN=g_fresh' >"$env_file"
chmod 600 "$env_file"
EOF
chmod +x "$tmp/wrap/devbox-secrets"
check_eq "wrapper: reloads after success" \
  "$(env -i PATH="$tmp/wrap:$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" zsh -c "source $INIT; devbox-secrets; printenv GITHUB_TOKEN")" "g_fresh"
rm -f "$env_file"
touch "$tmp/wrap-fail"
printf '%s\n' 'GITHUB_TOKEN=g_stale' >"$env_file"
chmod 600 "$env_file"
check_eq "wrapper: keeps the status of a failed run, no reload" \
  "$(env -i PATH="$tmp/wrap:$PATH" HOME="$HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" zsh -c "GITHUB_TOKEN=before; source $INIT; GITHUB_TOKEN=before; devbox-secrets; echo rc=\$?; echo \$GITHUB_TOKEN")" $'rc=1\nbefore'
rm -f "$tmp/wrap-fail"

# ======================= git credential helper =======================
cred() { # GITHUB_TOKEN-or-unset STDIN [OP]
  local op=${3:-get}
  if [[ $1 == unset ]]; then
    printf '%b' "$2" | env -u GITHUB_TOKEN git-credential-devbox "$op"
  else
    printf '%b' "$2" | GITHUB_TOKEN=$1 git-credential-devbox "$op"
  fi
}
gh_in='protocol=https\nhost=github.com\n\n'
check_eq "credential: token set, github.com" "$(cred ghp_abc.1-2 "$gh_in")" $'username=x-access-token\npassword=ghp_abc.1-2'
check_eq "credential: token unset: prints nothing" "$(cred unset "$gh_in")" ""
check_eq "credential: token empty: prints nothing" "$(cred '' "$gh_in")" ""
check_eq "credential: token with a space: prints nothing" "$(cred 'a b' "$gh_in")" ""
check_eq "credential: other host: prints nothing" "$(cred ghp_abc 'protocol=https\nhost=gitlab.com\n\n')" ""
check_eq "credential: lookalike host: prints nothing" "$(cred ghp_abc 'protocol=https\nhost=github.com.evil.example\n\n')" ""
check_eq "credential: http: prints nothing" "$(cred ghp_abc 'protocol=http\nhost=github.com\n\n')" ""
check_eq "credential: store: prints nothing" "$(cred ghp_abc "$gh_in" store)" ""
check_eq "credential: erase: prints nothing" "$(cred ghp_abc "$gh_in" erase)" ""
cred ghp_abc "$gh_in" >/dev/null
check_eq "credential: exit status 0" "$?" "0"

# End to end with the guest's generated system gitconfig and the real git.
git_cred() { # TOKEN-or-unset
  local -a envs=(GIT_CONFIG_SYSTEM="$GITCONFIG" GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false HOME="$HOME" PATH="$PATH")
  [[ $1 == unset ]] || envs+=(GITHUB_TOKEN="$1")
  printf 'protocol=https\nhost=github.com\n\n' | env -i "${envs[@]}" git credential fill 2>/dev/null
}
check_eq "git credential fill: helper gives the token" "$(git_cred ghp_e2e)" $'protocol=https\nhost=github.com\nusername=x-access-token\npassword=ghp_e2e'
check_lacks "git credential fill: no token, no password" "$(git_cred unset || true)" 'password='

if ((fails > 0)); then
  echo "$fails check(s) failed" >&2
  exit 1
fi
echo "all devbox-secrets checks passed"
