{
  outputs = {nixpkgs, ...}: let
    forAllSystems = f: builtins.mapAttrs f nixpkgs.legacyPackages;
  in {
    devShells = forAllSystems (system: pkgs: {
      default = pkgs.mkShellNoCC {
        packages = with pkgs; [bash zig zls];
      };
    });
  };
}
