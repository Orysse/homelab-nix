# API keys and the git credential of the devbox, fetched from OpenBao by hand at the start of a
# working session (imported by devbox-guest). Nothing long-lived on disk:
#   - `devbox-secrets` logs in to OpenBao with the `sso/oidc` method (role `devbox`, Pocket-ID,
#     callback on localhost:8250, so `ssh -L 8250:localhost:8250 devbox` from the owner's PC),
#     reads kv/apps/devbox/{deepseek,openrouter,github} and writes $XDG_RUNTIME_DIR/devbox-env
#     (tmpfs, mode 0600). The OpenBao token is never stored (no ~/.vault-token);
#   - zsh loads that file as text (board/devbox-env.zsh): only the three known keys, only plain
#     values, never `source`. Scripts such as job-triage read it themselves;
#   - git over HTTPS to github.com takes its password from $GITHUB_TOKEN (git-credential-devbox).
# The scripts live in board/ (not .nix, so import-tree skips them); shellcheck runs on them at
# build time. `bao` is not in the runtimeInputs of devbox-secrets: it comes from the PATH
# (tools.nix), so the test can put a stub in front.
{ config, lib, ... }:
let
  mkSecrets = pkgs: {
    devbox-secrets = pkgs.writeShellApplication {
      name = "devbox-secrets";
      runtimeInputs = [ pkgs.coreutils ];
      text = builtins.readFile ./board/devbox-secrets.sh;
    };
    git-credential-devbox = pkgs.writeShellApplication {
      name = "git-credential-devbox";
      runtimeInputs = [ ];
      text = builtins.readFile ./board/git-credential-devbox.sh;
    };
  };

  # The zsh function that reads the env file. A store path: the generated shell init sources it.
  loader = ./board/devbox-env.zsh;
in
{
  flake.modules.nixos.devbox-secrets = { pkgs, ... }:
    let secrets = mkSecrets pkgs;
    in {
      environment.systemPackages = [ secrets.devbox-secrets secrets.git-credential-devbox ];

      # Every interactive zsh (a new tmux window, an agent window) picks the file up. After
      # `devbox-secrets` the function reloads it in the shell that ran it.
      programs.zsh.interactiveShellInit = ''
        source ${loader}
        devbox-load-env
      '';

      # System-wide git config. Scoped to github.com over HTTPS; elsewhere git asks as usual.
      programs.git = {
        enable = true;
        config.credential."https://github.com".helper = lib.getExe secrets.git-credential-devbox;
      };
    };

  perSystem = { pkgs, ... }:
    let secrets = mkSecrets pkgs;
    in {
      packages = { inherit (secrets) devbox-secrets git-credential-devbox; };

      # devbox-secrets, the zsh loader and the git helper with a stub `bao`. The init text and the
      # gitconfig tested are the devbox guest's, so a missing import fails here.
      checks.devbox-secrets =
        let
          guest = config.flake.nixosConfigurations.nuc1.config.microvm.vms.devbox.config.config;
          init = guest.programs.zsh.interactiveShellInit;
          plain = builtins.unsafeDiscardStringContext;
        in
        assert lib.hasInfix (plain "source ${loader}") (plain init);
        assert lib.hasInfix "devbox-load-env" init;
        assert guest.programs.git.enable;
        pkgs.runCommand "devbox-secrets"
          {
            nativeBuildInputs = [
              secrets.devbox-secrets
              secrets.git-credential-devbox
              pkgs.zsh
              pkgs.git
              pkgs.coreutils
              pkgs.gnugrep
              pkgs.bash
            ];
            SNIPPET = loader;
            INIT = pkgs.writeText "devbox-zsh-init" init;
            GITCONFIG = pkgs.writeText "devbox-gitconfig" guest.environment.etc.gitconfig.text;
          } ''
          bash ${./board/tests/secrets.sh}
          touch $out
        '';
    };
}
