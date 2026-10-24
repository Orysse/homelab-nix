# shellcheck shell=bash
# git-credential-devbox: git credential helper for https://github.com, configured in the system
# git config of the devbox (secrets.nix). On `get` for github.com it answers with
# username=x-access-token and password=$GITHUB_TOKEN (set by the zsh loader of devbox-env).
# Without a usable token, for another host or protocol, and for store/erase, it prints nothing
# and git moves on. The token is only taken from the environment, and only if it has the shape
# of the values devbox-secrets writes.

[[ ${1:-} == get ]] || exit 0

protocol=""
host=""
while IFS= read -r line && [[ -n $line ]]; do
  case $line in
    protocol=*) protocol=${line#protocol=} ;;
    host=*) host=${line#host=} ;;
    *) ;;
  esac
done

[[ $protocol == https && $host == github.com ]] || exit 0
token=${GITHUB_TOKEN:-}
[[ $token =~ ^[A-Za-z0-9_.-]+$ ]] || exit 0
printf 'username=x-access-token\npassword=%s\n' "$token"
