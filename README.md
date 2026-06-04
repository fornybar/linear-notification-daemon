# Linear notification daemon setup

Nix flake for Linear desktop notification daemon.

## Outputs

- `packages.${system}.linear-notify`
- `packages.${system}.default`
- `nixosModules.linear-notify`
- `nixosModules.default`

## NixOS usage

```nix
{
  inputs.linear-notification-daemon.url = "github:fornybar/linear-notification-daemon";
  inputs.linear-notification-daemon.inputs.nixpkgs.follows = "nixpkgs";
}
```

```nix
{ inputs, ... }:
{
  imports = [ inputs.linear-notification-daemon.nixosModules.default ];

  services.linear-notify = {
    enable = true;
    user = "alice";
    tokenFile = "/run/secrets/linear-api-key";
  };
}
```
