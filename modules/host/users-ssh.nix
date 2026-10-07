# Accès root par clé uniquement. Partagé entre host et VMs.
{
  flake.modules.nixos.users-ssh = {
    users.users.root.openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBq0gKJgexGHmwZDov74uTUmYYKhg5zqPeQLwZFabCvp abel@thinkpad"
    ];

    services.openssh = {
      enable = true;
      openFirewall = true;
      settings = {
        PermitRootLogin = "prohibit-password";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
    };
  };
}
