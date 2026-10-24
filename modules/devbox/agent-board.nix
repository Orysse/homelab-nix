# The agent board: one JSON row per agent in ~/.local/state/agents, written by `agent-status`.
# `agent-status-remote` is the forced command for the dedicated SSH key of agents on other
# machines: it accepts one shape of command and never runs a shell. `board` is the fzf table in
# window 0 of the tmux session `devbox`; `devbox-session` creates or attaches that session (the
# zsh login hook in guest.nix runs it). The scripts live in board/ (not .nix, so import-tree
# skips them) and shellcheck runs on them at build time.
# tmux and fzf are not in the runtimeInputs of board and devbox-session: they come from the PATH
# (the owner's tmux, see tools.nix), as does `agent-run` (called by name, Ctrl-N in the board).
{ config, lib, ... }:
let
  mkBoard = pkgs: rec {
    agent-status = pkgs.writeShellApplication {
      name = "agent-status";
      runtimeInputs = [ pkgs.jq pkgs.util-linux pkgs.coreutils ];
      text = builtins.readFile ./board/agent-status.sh;
    };
    agent-status-remote = pkgs.writeShellApplication {
      name = "agent-status-remote";
      runtimeInputs = [ agent-status pkgs.coreutils ];
      text = builtins.readFile ./board/agent-status-remote.sh;
    };
    board = pkgs.writeShellApplication {
      name = "board";
      runtimeInputs = [ agent-status pkgs.jq pkgs.util-linux pkgs.coreutils pkgs.less ];
      text = builtins.readFile ./board/board.sh;
    };
    devbox-session = pkgs.writeShellApplication {
      name = "devbox-session";
      runtimeInputs = [ board pkgs.coreutils ];
      text = builtins.readFile ./board/devbox-session.sh;
    };
  };
in
{
  # Installs the board commands on the devbox (imported by devbox-guest).
  flake.modules.nixos.devbox-board = { pkgs, ... }:
    let board = mkBoard pkgs;
    in {
      environment.systemPackages = [
        board.agent-status
        board.agent-status-remote
        board.board
        board.devbox-session
      ];
    };

  perSystem = { pkgs, ... }:
    let board = mkBoard pkgs;
    in {
      packages = { inherit (board) agent-status agent-status-remote board devbox-session; };

      checks.agent-status = pkgs.runCommand "agent-status"
        {
          nativeBuildInputs = [ board.agent-status board.agent-status-remote pkgs.jq pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.bash ];
        } ''
        bash ${./board/tests/agent-status.sh}
        touch $out
      '';

      # The zsh login snippet of the devbox guest is checked here too: the eval assertion wants
      # the guards in the generated text, and the test runs it in a real zsh.
      checks.devbox-session =
        let
          guest = config.flake.nixosConfigurations.nuc1.config.microvm.vms.devbox.config.config;
          snippet = guest.programs.zsh.loginShellInit;
          guards = [ "-o interactive" "-o login" "-t 0" "SSH_CONNECTION" "TMUX" "exec devbox-session" ];
        in
        assert lib.all (g: lib.hasInfix g snippet) guards;
        pkgs.runCommand "devbox-session"
          {
            nativeBuildInputs = [
              board.board
              board.devbox-session
              board.agent-status
              pkgs.tmux
              pkgs.fzf
              pkgs.zsh
              pkgs.util-linux
              pkgs.jq
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.bash
            ];
            LOGIN_SNIPPET = pkgs.writeText "devbox-login-snippet.zsh" snippet;
          } ''
          bash ${./board/tests/session.sh}
          touch $out
        '';
    };
}
