![](./static/kirikae-logo.svg)

> 切り替え (kirikae) - ichidan verb, transitive verb - to change; to exchange; to convert; to renew; to throw a switch; to replace; to switch over

------------------------------------------------------------------------

A simple [NixOS](https://nixos.org) deployment tool inspired by [colmena](https://github.com/zhaofengli/colmena).

# Usage

Example flake setup:

``` nix
{
  description = "Example kirikae deployment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    {
      # Each nixosConfigurations key must match the corresponding kirikae.hosts key.
      # kirikae derives which NixOS config to build/deploy from the host key directly.
      nixosConfigurations = {
        example = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/example.nix ];
        };
        example2 = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [ ./hosts/example2.nix ];
        };        
      };
      kirikae.hosts = {
        example = {
          targetHost = "[::1]";
          targetUser = "root";
          targetPort = 2222;
        };
        example2 = {
          targetHost = "10.187.1.2";
          targetUser = "root";
          targetPort = 3333;
          nice = 100; # higher = deployed first (default 0)
        };
      };
    };
}
```

With this you can run:

```
kirikae -f path:. --on "ex*" --not-on "example2" apply
```

------------------------------------------------------------------------

```
kirikae [-f <flake>] [--on <nodes>] [--not-on <nodes>] <subcommand>

Subcommands:
  build          Build system closures
  apply          Build and deploy to hosts
  eval           Evaluate the hive configuration (hosts listed in descending nice order)
  shell <host>   Open an interactive shell on a host
  exec -- <cmd>  Run a command on all hosts matching the supplied filters

Options:
  -f, --flake <FLAKE>   Flake to deploy (default: ".")
  --on <NODES>          Comma-separated host filter
  --not-on <NODES>      Comma-separated host exclusion filter
  --sequential          Run hosts one at a time instead of in parallel
  --reboot              Reboot host(s) before activating the new config
  -h, --help            Show this help
```
