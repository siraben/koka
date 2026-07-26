{
  description = "Koka compiler (private development branch) with a reproducible build and dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        version = "3.2.7";

        # The whole working tree minus build/VCS noise. mimalloc is a submodule
        # and must be present for kklib to configure.
        src = pkgs.lib.cleanSourceWith {
          src = ./.;
          filter =
            path: type:
            let
              base = baseNameOf path;
            in
            !(builtins.elem base [
              ".git"
              ".stack-work"
              "dist-newstyle"
              "out"
              "result"
              ".direnv"
            ]);
        };

        koka = pkgs.callPackage ./nix/koka.nix {
          inherit src version;
        };

        # Native libraries the Milestone 3/4 packages bind against.
        nativeLibs = with pkgs; [
          sqlite
          sqlite.dev
          libuv
          libuv.dev
        ];
      in
      {
        packages = {
          inherit koka;
          default = koka;
        };

        devShells.default = pkgs.haskellPackages.shellFor {
          packages = _: [ koka ];
          nativeBuildInputs =
            (with pkgs; [
              cabal-install
              hpack
              alex
              cmake
              gnumake
              pkg-config
              gdb
              valgrind
              curl
              jq
              sqlite
            ])
            ++ nativeLibs;
          withHoogle = false;
          shellHook = ''
            export KOKA_DEV_ROOT="$PWD"
            echo "koka dev shell: ghc $(ghc --numeric-version), cabal $(cabal --numeric-version)"
          '';
        };

        # Shell for building and running Koka *programs* (not the compiler):
        # has the compiler from this tree plus the native deps on the path.
        devShells.user = pkgs.mkShell {
          nativeBuildInputs =
            (with pkgs; [
              koka
              stdenv.cc
              cmake
              gnumake
              pkg-config
              curl
              jq
              sqlite
            ])
            ++ nativeLibs;
        };
      }
    );
}
