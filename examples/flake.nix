{
  description = "Example kirikae deployment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    {
      # Each nixosConfigurations key must match the corresponding kirikae.hosts key.
      # kirikae derives which NixOS config to build/deploy from the host key directly.
      nixosConfigurations = {
        proxy = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/proxy.nix ];
        };
        vm-proxy = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/vm-proxy.nix ];
        };
        database = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/database.nix ];
        };
        vpn = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/vpn.nix ];
        };
      };

      # optional
      # expose systems as hydra jobs for pre-building.
      hydraJobs = builtins.mapAttrs (_: cfg: cfg.config.system.build.toplevel) self.nixosConfigurations;

      kirikae.hosts = {
        vm-proxy = {
          targetHost = "127.0.0.1";
          targetUser = "root";
          targetPort = 2222;
        };
        proxy = {
          targetHost = "10.0.0.1";
          targetUser = "root";
          targetPort = 22;
          nice = 4000; # evaluates and gets deployed first
        };
        database = {
          targetHost = "10.0.0.2";
          targetUser = "deploy";
          targetPort = 22;
          nice = 3000;
        };
        vpn = {
          targetHost = "203.0.113.5";
          targetUser = "root";
          targetPort = 2222;
          nice = 0; # default
        };
      };
    };
}
