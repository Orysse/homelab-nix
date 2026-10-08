{
  flake.modules.nixos.boot = {
    boot.loader.systemd-boot.enable = true;
    boot.loader.systemd-boot.configurationLimit = 20;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.initrd.systemd.enable = true;
    # No disk swap: VM RAM is reserved, zram is enough as a safety net.
    zramSwap.enable = true;
  };
}
