# Loader of $XDG_RUNTIME_DIR/devbox-env (written by devbox-secrets), sourced by the interactive
# zsh of the devbox (secrets.nix). The file is read as text, never sourced: only the three known
# keys are exported, only when the value matches [A-Za-z0-9_.-]+. The first line of a key decides
# (a bad first line leaves the key unset). The file must be a regular file (not a link) owned by
# this user with no group/world permission bit, else nothing is read. Silent when there is
# nothing to load.
devbox-load-env() {
  emulate -L zsh
  zmodload -F zsh/stat b:zstat 2>/dev/null || return 0
  [[ -n ${XDG_RUNTIME_DIR:-} ]] || return 0
  local file=$XDG_RUNTIME_DIR/devbox-env line key value
  local -A st seen
  local re='^[A-Za-z0-9_.-]+$'
  # lstat: a symlink is refused. mode 0170000 = file type, 0100000 = regular file.
  zstat -L -H st -- $file 2>/dev/null || return 0
  (( (st[mode] & 8#170000) == 8#100000 && st[uid] == EUID && (st[mode] & 8#077) == 0 )) || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    case $line in
      DEEPSEEK_API_KEY=*|OPENROUTER_API_KEY=*|GITHUB_TOKEN=*) ;;
      *) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    [[ -z ${seen[$key]:-} ]] || continue
    seen[$key]=1
    [[ $value =~ $re ]] || continue
    typeset -gx "$key=$value"
  done < $file
}

# After a successful `devbox-secrets` the new values are loaded into this shell.
devbox-secrets() {
  command devbox-secrets "$@" || return
  devbox-load-env
}
