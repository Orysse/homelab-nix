{
  flake.modules.nixos.boot = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.systemd-boot.configurationLimit = 20;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.initrd.systemd.enable = true;
    # Pas de swap disque : la RAM des VMs est réservée, zram suffit en filet.
    zramSwap.enable = true;
  };
}
