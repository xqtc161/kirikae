{ ... }: {
  networking.hostName = "vpn";

  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };

  boot.loader.grub.device = "/dev/sda";

  system.stateVersion = "25.05";
}
