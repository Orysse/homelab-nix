# The agent board: one JSON row per agent in ~/.local/state/agents, written by `agent-status`.
# `agent-status-remote` is the forced command for the dedicated SSH key of agents on other
# machines: it accepts one shape of command and never runs a shell. `board` is the fzf table in
# the first window of the tmux session `devbox`; `devbox-session` creates or attaches that session (the
# zsh login hook in guest.nix runs it). The scripts live in board/ (not .nix, so import-tree
# skips them) and shellcheck runs on them at build time.
# `agent-run` starts an agent in its own window and keeps its row; `agent-hook` is the Claude Code
# hook that writes the row of a session (registered in the managed settings below).
# tmux and fzf are not in the runtimeInputs of board, devbox-session and agent-run: they come from the PATH
# (the owner's tmux, see tools.nix), as does `agent-run` for the board (called by name, Ctrl-N).
# `job-triage` is the example scheduled job (units in jobs.nix): it keeps the row `job-triage`.
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
    # tmux is not in the runtimeInputs (the owner's tmux comes from the PATH, as for board), and
    # neither are claude and opencode: the agent is looked up on the PATH of the caller.
    agent-run = pkgs.writeShellApplication {
      name = "agent-run";
      runtimeInputs = [ agent-status pkgs.util-linux pkgs.coreutils pkgs.gnugrep ];
      text = builtins.readFile ./board/agent-run.sh;
    };
    agent-hook = pkgs.writeShellApplication {
      name = "agent-hook";
      runtimeInputs = [ agent-status pkgs.jq pkgs.coreutils ];
      text = builtins.readFile ./board/agent-hook.sh;
    };
    # The example scheduled job (units in jobs.nix). claude and curl come from the PATH, as for agent-run.
    job-triage = pkgs.writeShellApplication {
      name = "job-triage";
      runtimeInputs = [ agent-status pkgs.jq pkgs.util-linux pkgs.coreutils pkgs.gnugrep ];
      text = builtins.readFile ./board/job-triage.sh;
    };
  };

  # Claude Code (2.1.289, read in the binary) reads /etc/claude-code/managed-settings.json on
  # Linux. `hooks` maps an event name to a list of
  # { matcher?, hooks: [ { type = "command"; command; timeout (seconds) } ] }, and each hook gets
  # its JSON on stdin (session_id, cwd, hook_event_name, ...). The settings carry hooks only, so
  # the owner's own settings and hooks stay in effect.
  hookEvents = [ "SessionStart" "Notification" "Stop" "UserPromptSubmit" "SessionEnd" ];
  managedSettings = pkgs:
    let board = mkBoard pkgs;
    in builtins.toJSON {
      hooks = lib.genAttrs hookEvents (event: [{
        hooks = [{
          type = "command";
          command = "${lib.getExe board.agent-hook} ${event}";
          timeout = 5;
        }];
      }]);
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
        board.agent-run
        board.agent-hook
        board.job-triage
      ];

      environment.etc."claude-code/managed-settings.json".text = managedSettings pkgs;
    };

  perSystem = { pkgs, ... }:
    let board = mkBoard pkgs;
    in {
      packages = { inherit (board) agent-status agent-status-remote board devbox-session agent-run agent-hook job-triage; };

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

      # agent-run and agent-hook with stub agents on a private tmux socket. The managed settings
      # tested are the ones of the devbox guest, so a missing import fails here.
      # job-triage with stub claude and curl, and the guest's units: the nightly timer, linger for
      # abel and the boot reconcile (the units are in jobs.nix, so a missing import fails here).
      checks.job-triage =
        let
          guest = config.flake.nixosConfigurations.nuc1.config.microvm.vms.devbox.config.config;
          timer = guest.systemd.user.timers.job-triage;
          reconcile = guest.systemd.user.services.agent-reconcile;
        in
        assert timer.timerConfig.OnCalendar == "*-*-* 03:00:00";
        assert timer.wantedBy == [ "timers.target" ];
        assert guest.users.users.abel.linger == true;
        assert reconcile.wantedBy == [ "default.target" ];
        assert lib.hasSuffix "agent-status reconcile" reconcile.serviceConfig.ExecStart;
        assert lib.hasSuffix "/job-triage" guest.systemd.user.services.job-triage.serviceConfig.ExecStart;
        pkgs.runCommand "job-triage"
          {
            nativeBuildInputs = [
              board.job-triage
              board.agent-status
              pkgs.jq
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.bash
            ];
          } ''
          bash ${./board/tests/job.sh}
          touch $out
        '';

      checks.agent-run =
        let
          guest = config.flake.nixosConfigurations.nuc1.config.microvm.vms.devbox.config.config;
          settings = guest.environment.etc."claude-code/managed-settings.json".text;
        in
        pkgs.runCommand "agent-run"
          {
            nativeBuildInputs = [
              board.agent-run
              board.agent-hook
              board.agent-status
              pkgs.tmux
              pkgs.util-linux
              pkgs.jq
              pkgs.coreutils
              pkgs.findutils
              pkgs.gnugrep
              pkgs.bash
            ];
            MANAGED_SETTINGS = pkgs.writeText "managed-settings.json" settings;
            AGENT_HOOK_BIN = lib.getExe board.agent-hook;
          } ''
          bash ${./board/tests/run.sh}
          touch $out
        '';
    };
}
