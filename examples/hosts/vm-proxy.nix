{ ... }:
{
  imports = [ ./proxy.nix ];

  # Forward host port 2222 → guest port 22 when running as a QEMU VM.
  # virtualisation.forwardPorts = [
  #   { from = "host"; host.port = 2222; guest.port = 22; }
  # ];

  services.openssh = {
    enable = true;
    settings.PermitRootLogin = "yes";
  };

  # Replace with your own public key.
  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN7UkcmSVo+SeB5Obevz3mf3UHruYxn0UHUzoOs2gDBy xqtc@heroin.trade"
  ];
}
