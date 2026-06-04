{
  description = "Linear desktop notification daemon";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };

      module = import ./modules/nixos/linear-notify.nix;

      mkChecks =
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          inherit (self.packages.${system}) linear-notify;

          package-smoke = pkgs.callPackage ./tests/package-smoke.nix {
            linear-notify = self.packages.${system}.linear-notify;
          };

          nixos-module-eval = pkgs.callPackage ./tests/module-eval.nix {
            module = self.nixosModules.linear-notify;
            nixosSystem = nixpkgs.lib.nixosSystem;
            inherit system;
          };

          nixos-linear-notify = pkgs.testers.runNixOSTest (
            import ./tests/nixos-linear-notify.nix {
              inherit pkgs;
              module = self.nixosModules.linear-notify;
            }
          );
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          linear-notify = pkgs.callPackage ./packages/linear-notify/package.nix { };
        in
        {
          inherit linear-notify;
          default = linear-notify;
        }
      );

      nixosModules = {
        linear-notify = module;
        default = module;
      };

      checks = forAllSystems mkChecks;

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixfmt
              python3
            ];
          };
        }
      );
    };
}
