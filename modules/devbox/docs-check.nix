# Check that the devbox runbook (docs/devbox.md) still covers what the code needs from the owner.
# Small on purpose: the file exists and names every OpenBao key that devbox-secrets reads, the
# tag, and the OIDC callback. The OpenBao paths are read from board/devbox-secrets.sh (the lines
# `VARIABLE:devbox/<name>` of its `entries` list), not written out again here, so a fourth secret
# added to the script fails this check until the runbook lists it.
# Not checked here: the Headscale policy (it lives in homelab-cluster).
{ lib, ... }:
let
  runbook = ../../docs/devbox.md;

  scriptLines = lib.splitString "\n" (builtins.readFile ./board/devbox-secrets.sh);
  entryOf = line: builtins.match " +([A-Z][A-Z0-9_]*):(devbox/[a-z0-9._-]+)" line;
  entries = lib.concatMap (l: lib.optional (entryOf l != null) (entryOf l)) scriptLines;
  # [ [ "DEEPSEEK_API_KEY" "devbox/deepseek" ] ... ]
  kvPaths = map (e: "kv/apps/${lib.elemAt e 1}") entries;
  envNames = map (e: lib.elemAt e 0) entries;
in
{
  perSystem = { pkgs, ... }: {
    checks.devbox-docs =
      # A missing script format must not make the check pass by having nothing to look for.
      assert lib.assertMsg (lib.length entries >= 3)
        "devbox-docs: found ${toString (lib.length entries)} entries in board/devbox-secrets.sh, expected at least 3";
      pkgs.runCommand "devbox-docs"
        {
          nativeBuildInputs = [ pkgs.gnugrep ];
          DOC = if builtins.pathExists runbook then runbook else "";
          KV_PATHS = lib.concatStringsSep "\n" kvPaths;
          ENV_NAMES = lib.concatStringsSep "\n" envNames;
        }
        ''
          fail() { echo "devbox-docs: $*" >&2; exit 1; }
          [ -n "$DOC" ] || fail "docs/devbox.md does not exist"

          need() { grep -qF -- "$1" "$DOC" || fail "docs/devbox.md does not mention: $1"; }
          while IFS= read -r p; do need "$p"; done <<<"$KV_PATHS"
          while IFS= read -r v; do need "$v"; done <<<"$ENV_NAMES"
          need "tag:devbox"
          need "http://localhost:8250/oidc/callback"
          need "ssh -L 8250:localhost:8250"
          need "microvm@devbox"
          need "statusKey"
          need "Known limits"
          need "auth-key"
          need "--tags tag:devbox"

          # The first login runs as root from a key file: nothing in the runbook may bring back the
          # operator setting (nobody could use it, and the guest no longer sets it).
          if grep -qF -- '--operator' "$DOC"; then
            fail "docs/devbox.md mentions --operator"
          fi

          # Headscale refuses a node that sends tags together with a pre-auth key (the tags come
          # from the key): no command line of the runbook (a line that starts with the command, as
          # in a code block; prose may name the flag) may do both.
          if grep -E '^[[:space:]]*tailscale up' "$DOC" | grep -qF -- '--advertise-tags'; then
            fail "a 'tailscale up' command in docs/devbox.md uses --advertise-tags; tags come from the pre-auth key"
          fi
          touch $out
        '';
  };
}
