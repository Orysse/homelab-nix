# The agent board: one JSON row per agent in ~/.local/state/agents, written by `agent-status`.
# `agent-status-remote` is the forced command for the dedicated SSH key of agents on other
# machines: it accepts one shape of command and never runs a shell. The scripts live in
# board/ (not .nix, so import-tree skips them) and shellcheck runs on them at build time.
{ config, ... }:
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
  };
in
{
  # Installs the board commands on the devbox (imported by devbox-guest).
  flake.modules.nixos.devbox-board = { pkgs, ... }:
    let board = mkBoard pkgs;
    in {
      environment.systemPackages = [ board.agent-status board.agent-status-remote ];
    };

  perSystem = { pkgs, ... }:
    let board = mkBoard pkgs;
    in {
      packages = { inherit (board) agent-status agent-status-remote; };

      checks.agent-status = pkgs.runCommand "agent-status"
        {
          nativeBuildInputs = [ board.agent-status board.agent-status-remote pkgs.jq pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.bash ];
        } ''
        bash ${./board/tests/agent-status.sh}
        touch $out
      '';
    };
}
