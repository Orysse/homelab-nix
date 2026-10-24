# The devbox's network exposure: Tailscale and SSH.
# The Tailscale join runs as root at boot, from a key file the owner puts on the host once.
# `authKeyFile` is only a PATH, on the persisted share (host: /srv/data/devbox/tailscale/auth-key,
# root-owned, 0600): no key material in the repository. NixOS's `tailscaled-autoconnect` unit
# reads it while the backend is NeedsLogin (first boot, or a node removed from Headscale) and runs
# `tailscale up --auth-key <file> <extraUpFlags>`; once the state is Running it does nothing and
# never opens the file again, so the owner deletes it after the join (runbook). A missing file at
# that moment makes `tailscale up` wait for a browser login until systemd's start timeout kills
# the unit; `systemctl restart tailscaled-autoconnect` runs it again. Login is as root because
# nobody else could: root cannot log in over SSH and `abel` has no sudo.
# The key is created with `--tags tag:devbox`: Headscale takes the tag from the key and rejects a
# client that sends --advertise-tags together with a key (checked on v0.29.5), so the flag appears
# nowhere. extraUpFlags are applied only together with authKeyFile; --accept-dns=false is in both
# lists because `tailscale up` refuses to leave out a setting that `tailscale set` made non-default
# (a node that has to register again).
# SSH: `abel` only, keys only, on tailscale0 and from the host (break-glass from the LAN).
{ config, ... }:
let
  inherit (config) cluster;
in
{
  flake.modules.nixos.devbox-network = { lib, node, ... }:
    let
      hostAddress = cluster.hosts.${cluster.devboxes.${node}.host}.address;
    in
    {
      services.tailscale = {
        enable = true;
        authKeyFile = "/var/lib/tailscale/auth-key"; # a path on the share, not a secret
        extraUpFlags = [
          "--login-server=https://hs.abe.lc"
          "--hostname=${node}"
          "--accept-dns=false"
        ];
        extraSetFlags = [ "--accept-dns=false" ];
      };

      # users-ssh (imported by microvm-guest) is written for hosts: undo what the devbox
      # must not have. Root's keys stay there, but root cannot log in; `abel` is the only login.
      services.openssh = {
        openFirewall = lib.mkForce false;
        settings = {
          PermitRootLogin = lib.mkForce "no";
          PasswordAuthentication = lib.mkForce false;
          KbdInteractiveAuthentication = lib.mkForce false;
        };
      };

      # extraInputRules is nftables-only.
      networking.nftables.enable = true;
      networking.firewall = {
        interfaces.tailscale0.allowedTCPPorts = [ 22 ];
        extraInputRules = "ip saddr ${hostAddress} tcp dport 22 accept";
      };
    };

  # Eval-only check on nuc1's guest `devbox`: where port 22 is open and how Tailscale is set.
  perSystem = { lib, pkgs, ... }: {
    checks.devbox-ssh-rules =
      let
        guest = config.flake.nixosConfigurations.nuc1.config.microvm.vms.devbox.config.config;
        fw = guest.networking.firewall;
        ssh = guest.services.openssh;
        otherIfaces = lib.removeAttrs fw.interfaces [ "tailscale0" ];
        opens22 = i: lib.elem 22 i.allowedTCPPorts
          || lib.any (r: r.from <= 22 && 22 <= r.to) i.allowedTCPPortRanges;
        tsFlags = guest.services.tailscale.extraUpFlags ++ guest.services.tailscale.extraSetFlags;
        rules22 = lib.length (lib.splitString "dport 22" fw.extraInputRules) - 1;
      in
      # sshd: no automatic firewall hole, only abel, keys only.
      assert ssh.openFirewall == false;
      assert ssh.settings.PermitRootLogin == "no";
      assert ssh.settings.PasswordAuthentication == false;
      assert ssh.settings.KbdInteractiveAuthentication == false;
      # Port 22: tailscale0 and nuc1 only, nothing else.
      assert fw.interfaces.tailscale0.allowedTCPPorts == [ 22 ];
      assert guest.networking.nftables.enable;
      assert lib.hasInfix "ip saddr 192.168.1.200 tcp dport 22 accept" fw.extraInputRules;
      assert rules22 == 1;
      assert !(opens22 fw);
      assert !(lib.any opens22 (lib.attrValues otherIfaces));
      # Tailscale: the join runs as root at boot from a key file on the persisted share. The
      # option holds a path only (a plain string, not a store path: no key material in the
      # repository); the tag is the key's, so no --advertise-tags; no --operator anywhere.
      assert guest.services.tailscale.enable;
      assert guest.services.tailscale.authKeyFile == "/var/lib/tailscale/auth-key";
      assert builtins.isString guest.services.tailscale.authKeyFile;
      assert guest.systemd.services ? tailscaled-autoconnect;
      assert lib.elem "--login-server=https://hs.abe.lc" guest.services.tailscale.extraUpFlags;
      assert lib.elem "--hostname=devbox" guest.services.tailscale.extraUpFlags;
      assert lib.elem "--accept-dns=false" guest.services.tailscale.extraUpFlags;
      assert lib.elem "--accept-dns=false" guest.services.tailscale.extraSetFlags;
      assert !(lib.any (lib.hasInfix "operator") tsFlags);
      assert !(lib.any (lib.hasInfix "advertise-tags") tsFlags);
      assert !(lib.any (lib.hasInfix "auth-key") tsFlags);
      pkgs.runCommand "devbox-ssh-rules" { } "touch $out";
  };
}
