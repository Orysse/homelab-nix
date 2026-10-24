# The devbox guest, on top of microvm-guest (VM plumbing, journal upload, zram, swappiness):
# the user `abel`, a home and a Tailscale state that outlive the disposable root, and a
# memory cap on the user's processes so a runaway agent cannot starve the VM.
# Not self-sufficient: it must be imported next to microvm-guest (microvm-host does).
{ config, ... }:
let
  topModules = config.flake.modules.nixos;
  inherit (config) cluster;
in
{
  flake.modules.nixos.devbox-guest = { config, lib, pkgs, node, ... }: {
    imports = [
      topModules.devbox-network
      topModules.devbox-tools
      topModules.devbox-board
      topModules.devbox-jobs
      topModules.devbox-secrets
      # Read from the topology; an option only so that the eval check can override it.
      ({ lib, node, ... }: {
        options.devbox.statusKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = cluster.devboxes.${node}.statusKey;
          description = "Public SSH key of remote agents; null: none.";
        };
      })
    ];

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
      # Same keys as root (users-ssh), with full access. Then, when statusKey is set, the key of
      # remote agents: it can only run agent-status-remote (`restrict` = no pty, no forwarding,
      # no ~/.ssh/rc). The lines go into authorized_keys as they are, options first.
      openssh.authorizedKeys.keys = config.users.users.root.openssh.authorizedKeys.keys
        ++ lib.optional (config.devbox.statusKey != null)
        ''command="agent-status-remote",restrict ${config.devbox.statusKey}'';
    };

    # One public key on one line. A newline would add a second, unrestricted key to the file.
    assertions = [{
      assertion = config.devbox.statusKey == null
        || builtins.match "(ssh-ed25519|sk-ssh-ed25519@openssh\\.com|ssh-rsa|ecdsa-sha2-nistp[0-9]+|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/=]+( [^\n]*)?" config.devbox.statusKey != null;
      message = "cluster.devboxes.${node}.statusKey must be one public key on one line (type, base64, optional comment).";
    }];

    systemd.tmpfiles.rules = [ "d /home/abel/work 0755 abel users -" ];

    # 2.5 GB of RAM in total: the user's processes get 2 GB at most, the rest stays for the
    # kernel, sshd and the journal. Hitting the cap kills the offender, not the VM.
    systemd.slices."user-1000".sliceConfig.MemoryMax = "2G";
  };

  # Eval-only check on nuc1's guest `devbox`: the restricted status key is added when
  # `statusKey` is set, only on that key, and the full-access keys never carry the restriction.
  perSystem = { lib, pkgs, ... }: {
    checks.devbox-status-key =
      let
        nuc1 = config.flake.nixosConfigurations.nuc1;
        # abel's authorized_keys lines, with statusKey replaced inside the guest.
        guestWith = statusKey:
          (nuc1.extendModules {
            modules = [{ microvm.vms.devbox.config.devbox.statusKey = statusKey; }];
          }).config.microvm.vms.devbox.config.config;
        keysWith = statusKey: (guestWith statusKey).users.users.abel.openssh.authorizedKeys.keys;
        failedAssertions = statusKey: lib.filter (a: !a.assertion) (guestWith statusKey).assertions;
        defaultKeys = nuc1.config.microvm.vms.devbox.config.config.users.users.abel.openssh.authorizedKeys.keys;
        dummy = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMMYDUMM status@test";
        prefix = ''command="agent-status-remote",restrict '';
        restricted = lib.filter (lib.hasPrefix prefix);
        withKey = keysWith dummy;
        withoutKey = keysWith null;
        rootKeys = nuc1.config.users.users.root.openssh.authorizedKeys.keys;
      in
      # Keys set: exactly one restricted line, ending in the dummy key; the other lines are root's keys, untouched.
      assert restricted withKey == [ (prefix + dummy) ];
      assert lib.filter (k: !(lib.hasPrefix prefix k)) withKey == rootKeys;
      assert rootKeys != [ ];
      # Any option text on a full-access key (command=, restrict, from=...) would be a hole.
      assert lib.all (k: lib.hasPrefix "ssh-" k || lib.hasPrefix "sk-" k || lib.hasPrefix "ecdsa-" k) rootKeys;
      # Key null: no restricted line, and the full-access keys are the same.
      assert restricted withoutKey == [ ];
      assert withoutKey == rootKeys;
      # Without an override, the guest follows the topology.
      assert defaultKeys == keysWith cluster.devboxes.devbox.statusKey;
      # The key is one line of the shape `type base64 [comment]`: a newline or leading options
      # would add a second key, or replace the restriction.
      assert failedAssertions dummy == [ ];
      assert failedAssertions null == [ ];
      assert lib.all (k: lib.length (failedAssertions k) == 1) [
        "${dummy}\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDUMMY2 other@host"
        ''command="id" ${dummy}''
        "not-a-key"
        ""
      ];
      pkgs.runCommand "devbox-status-key" { } "touch $out";
  };
}
