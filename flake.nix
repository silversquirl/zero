{
  inputs = {
    nixpkgs.url = "nixpkgs";
    zig.url = "github:silversquirl/zig-flake";
    zls.url = "github:zigtools/zls/pull/2457/head";

    zig.inputs.nixpkgs.follows = "nixpkgs";
    zls.inputs.nixpkgs.follows = "nixpkgs";
    zls.inputs.zig-overlay.follows = "zig";
  };

  outputs = {
    nixpkgs,
    zig,
    zls,
    ...
  }: let
    forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (system: pkgs: {
      default = pkgs.mkShellNoCC {
        packages = [
          pkgs.bash
          zig.packages.${system}.zig_0_15_1
          zls.packages.${system}.default
        ];
      };
    });

    packages = forAllSystems (system: pkgs: {
      default = zig.packages.${system}.zig_0_15_1.makePackage {
        pname = "zig-flake-template";
        version = "0.0.0";
        src = ./.;
        zigReleaseMode = "fast";
        # depsHash = "<replace this with the hash Nix provides in its error message>"
      };
    });
  };
}
