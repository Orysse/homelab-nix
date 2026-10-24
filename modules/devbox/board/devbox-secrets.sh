# shellcheck shell=bash
# devbox-secrets: fetches the API keys and the git credential of the devbox from OpenBao and
# writes them to $XDG_RUNTIME_DIR/devbox-env (tmpfs, mode 0600). Run by hand at the start of a
# working session; zsh and job-triage read the file as text.
#   - login: `bao login -method=oidc -path=sso/oidc role=devbox` with -token-only (= -field=token
#     -no-store): the token is printed, never written to ~/.vault-token. It lives in a shell
#     variable and in BAO_TOKEN of the three reads, never in an argument list. The login waits for
#     the browser: from another PC, `ssh -L 8250:localhost:8250 devbox` first (the OIDC callback);
#   - reads: kv/apps/devbox/{deepseek,openrouter,github}, field `value`. The KV v2 mount is
#     `kv/apps` (homelab-cluster, config.yaml: SecretEngineMount path kv + name apps), so the
#     API path is kv/apps/data/devbox/<name> and the CLI call is `-mount=kv/apps devbox/<name>`
#     (checked against a dev server);
#   - file: lines `KEY=value`, no export, no quotes. A value must match [A-Za-z0-9_.-]+ (the
#     strictest shape any reader of the file accepts), else the run fails and says which key (the
#     value is never printed). The file is written to a temp file in the same directory and renamed
#     over the old one, only after the login and all three reads succeeded: any failure leaves the
#     old file exactly as it was.
# `bao` comes from the PATH of the caller (tools.nix).

BAO_ADDR=https://bao.int.abe.lc
export BAO_ADDR
unset BAO_TOKEN

die() {
  echo "devbox-secrets: $*" >&2
  exit 1
}

runtime_dir=${XDG_RUNTIME_DIR:-}
[[ -n $runtime_dir ]] || die "XDG_RUNTIME_DIR is not set (log in again, or start a user session)"
[[ -d $runtime_dir ]] || die "XDG_RUNTIME_DIR ($runtime_dir) is not a directory"
env_file=$runtime_dir/devbox-env

umask 077
tmp_file=""
trap '[[ -z $tmp_file ]] || rm -f "$tmp_file"' EXIT

token=$(bao login -method=oidc -path=sso/oidc -no-store -token-only role=devbox) ||
  die "login to OpenBao ($BAO_ADDR) failed or was cancelled, nothing changed"
[[ -n $token ]] || die "OpenBao ($BAO_ADDR) returned no token, nothing changed"

# One entry per variable: NAME:path in the KV mount.
entries=(
  DEEPSEEK_API_KEY:devbox/deepseek
  OPENROUTER_API_KEY:devbox/openrouter
  GITHUB_TOKEN:devbox/github
)
content=""
for entry in "${entries[@]}"; do
  name=${entry%%:*}
  path=${entry#*:}
  value=$(BAO_TOKEN=$token bao kv get -mount=kv/apps -field=value "$path") ||
    die "could not read kv/apps/$path from OpenBao ($BAO_ADDR), nothing changed"
  [[ $value =~ ^[A-Za-z0-9_.-]+$ ]] ||
    die "the value of kv/apps/$path in OpenBao for $name is empty or has characters outside A-Za-z0-9_.-, nothing changed"
  content+="$name=$value"$'\n'
done
unset token

tmp_file=$(mktemp "$runtime_dir/.devbox-env.XXXXXX") || die "cannot create a file in $runtime_dir, nothing changed"
printf '%s' "$content" >"$tmp_file" || die "cannot write $tmp_file, nothing changed"
chmod 600 "$tmp_file"
mv -f "$tmp_file" "$env_file" || die "cannot replace $env_file, nothing changed"
tmp_file=""
echo "devbox-secrets: $env_file updated (DEEPSEEK_API_KEY, OPENROUTER_API_KEY, GITHUB_TOKEN)"
