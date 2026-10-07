{
  flake.modules.nixos.base = { pkgs, ... }: {
    nix.settings = {
      experimental-features = [ "nix-command" "flakes" ];
      trusted-users = [ "root" ];
    };

    time.timeZone = "Europe/Paris";
    i18n.defaultLocale = "en_US.UTF-8";
    console.keyMap = "us";

    environment.systemPackages = with pkgs; [ vim git htop ];

    system.stateVersion = "26.11";
  };
}
