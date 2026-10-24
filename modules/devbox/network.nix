# The devbox's network exposure: Tailscale and SSH.
# The first Tailscale login is manual, by design: NixOS applies `extraUpFlags` only together
# with `authKeyFile`, and the pre-auth key (a secret) must not enter the repository. The owner
# enters it once (runbook): `tailscale up --login-server https://hs.abe.lc --hostname devbox
# --accept-dns=false --operator=abel --auth-key <key>`, with a pre-auth key created with
# `--tags tag:devbox`: Headscale takes the tag from the key and refuses a client that sends
# --advertise-tags together with a key (checked on v0.29.5). The node identity then
# lives in /var/lib/tailscale, persisted by the virtiofs share (guest.nix). Nix only pins
# what `tailscale set` can: no DNS takeover, and `abel` as the Tailscale operator. Without
# the operator nobody could run that login: root cannot log in over SSH and `abel` has no
# sudo. `tailscale up` must then repeat both flags, it refuses to leave a non-default one out.
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
        extraSetFlags = [ "--accept-dns=false" "--operator=abel" ];
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
      # Tailscale: the first login (login server, hostname, key; the tag is the key's) is manual.
      assert guest.services.tailscale.enable;
      assert guest.services.tailscale.authKeyFile == null;
      assert lib.elem "--accept-dns=false" guest.services.tailscale.extraSetFlags;
      assert lib.elem "--operator=abel" guest.services.tailscale.extraSetFlags;
      assert !(lib.any (lib.hasInfix "login-server") guest.services.tailscale.extraUpFlags);
      pkgs.runCommand "devbox-ssh-rules" { } "touch $out";
  };
}
