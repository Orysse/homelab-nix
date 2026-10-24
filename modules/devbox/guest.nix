# The devbox guest, on top of microvm-guest (VM plumbing, journal upload, zram, swappiness):
# the user `abel`, a home and a Tailscale state that outlive the disposable root, and a
# memory cap on the user's processes so a runaway agent cannot starve the VM.
# Not self-sufficient: it must be imported next to microvm-guest (microvm-host does).
{ config, ... }:
let
  topModules = config.flake.modules.nixos;
in
{
  flake.modules.nixos.devbox-guest = { config, pkgs, ... }: {
    imports = [ topModules.devbox-network topModules.devbox-tools topModules.devbox-board ];

    microvm.shares = [
      {
        source = "/srv/data/devbox/home";
        mountPoint = "/home/abel";
        tag = "home";
        proto = "virtiofs";
      }
      {
        source = "/srv/data/devbox/tailscale";
        mountPoint = "/var/lib/tailscale";
        tag = "tailscale";
        proto = "virtiofs";
      }
    ];

    programs.zsh.enable = true;
    # An interactive SSH login lands in the tmux session `devbox` (board in the first window). Anything
    # else keeps its shell untouched: scp, rsync and `ssh devbox cmd` have no terminal on stdin
    # and are not interactive logins, and a shell already in tmux must not nest another.
    programs.zsh.loginShellInit = ''
      if [[ -o interactive && -o login && -t 0 && -n $SSH_CONNECTION && -z $TMUX ]]; then
        exec devbox-session
      fi
    '';
    users.users.abel = {
      isNormalUser = true;
      uid = 1000;
      home = "/home/abel";
      shell = pkgs.zsh;
      # Same keys as root (users-ssh).
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys;
    };

    systemd.tmpfiles.rules = [ "d /home/abel/work 0755 abel users -" ];

    # 2.5 GB of RAM in total: the user's processes get 2 GB at most, the rest stays for the
    # kernel, sshd and the journal. Hitting the cap kills the offender, not the VM.
    systemd.slices."user-1000".sliceConfig.MemoryMax = "2G";
  };
}
