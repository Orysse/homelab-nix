{
  flake.modules.nixos.users-ssh = {
    users.users.root.openssh.authorizedKeys.keys = [
      # YubiKey (OpenPGP auth key, serial 36007760): primary.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF746gJQqeHJiI8KdIT7TQpelU0oy/WeW9SxBwR9HXSC cardno:36_007_760"
      # Laptop file key: fallback when the YubiKey is not at hand (passphrase-protected).
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBq0gKJgexGHmwZDov74uTUmYYKhg5zqPeQLwZFabCvp abel@thinkpad"
      # Lenny, cluster admin: root on the hosts and the VMs.
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMr5vQB5PdB55C8FbVuQQjuBoSOeus+X+Wi9Kf45Rmko lenny@Lenny"
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
