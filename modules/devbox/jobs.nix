# Scheduled agent jobs of the devbox, as systemd user units of `abel` (imported by devbox-guest).
# `linger` starts abel's user manager at boot, without a login: the timers run, and
# agent-reconcile.service marks the board rows whose agent died with the old boot as `lost`
# (nothing is resumed). The jobs themselves are scripts of the board package set
# (agent-board.nix, job-triage.sh), found in the system profile like the agents they run.
{
  flake.modules.nixos.devbox-jobs = { ... }:
    let
      profile = "/run/current-system/sw";
    in
    {
      users.users.abel.linger = true;

      systemd.user.services.agent-reconcile = {
        description = "Mark the agent board rows left by a dead process as lost";
        wantedBy = [ "default.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${profile}/bin/agent-status reconcile";
        };
      };

      # Daily example job: a read-only summary of the open Renovate pull requests. A missed run
      # (VM down at 03:00) is not replayed: the next night's report covers it.
      systemd.user.services.job-triage = {
        description = "Nightly triage of the open Renovate pull requests";
        # claude and curl are looked up on the PATH, the unit has no other.
        path = [ profile ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${profile}/bin/job-triage";
          TimeoutStartSec = "30min";
        };
      };
      systemd.user.timers.job-triage = {
        description = "Nightly triage of the open Renovate pull requests";
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "*-*-* 03:00:00";
      };
    };
}
