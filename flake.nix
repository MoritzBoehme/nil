{
  description = "Language Server for Nix Expression Language";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.flake-utils.follows = "flake-utils";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, flake-utils, nixpkgs, rust-overlay }:
    let
      inherit (builtins) substring;
      inherit (nixpkgs) lib;

      mtime = self.lastModifiedDate;
      date = "${substring 0 4 mtime}-${substring 4 2 mtime}-${substring 6 2 mtime}";
      rev = self.rev or (throw "Git changes are not committed");

      mkNil = { rustPlatform, nix, ... }:
        rustPlatform.buildRustPackage {
          pname = "nil";
          version = "unstable-${date}";
          src = self;
          cargoLock.lockFile = self + "/Cargo.lock";

          nativeBuildInputs = [ nix.out ];

          CFG_RELEASE = "git-${rev}";
        };

      mkCocNil = { runCommand, nodejs, esbuild }:
        runCommand "coc-nil-unstable-${date}" {
          nativeBuildInputs = [ nodejs esbuild ];
          src = ./editors/coc-nil;
        } ''
          cp -r --no-preserve=all $src ./source
          cd source
          npm run build --offline
          mkdir -p $out
          cp -rt $out lib package{,-lock}.json
        '';

    in
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          rustPkgs = rust-overlay.packages.${system};

          clippyFlags = lib.concatStringsSep " " [
            "-D" "warnings"
            "-D" "clippy::dbg_macro"
            "-D" "clippy::semicolon_if_nothing_returned"
            "-D" "clippy::todo"
          ];

          pre-commit = pkgs.writeShellScriptBin "pre-commit" ''
            set -e
            die() { echo "$*" >&2; exit 1; }

            if git_dir="$(git rev-parse --show-toplevel)"; then
              cd "$git_dir"
            fi
            cargo fmt --all --check \
              || die 'Format failed'
            cargo clippy --all --all-targets -- ${clippyFlags} \
              || die 'Clippy failed'

            ( cd editors/coc-nil; npm run lint )
          '';

        in
        rec {
          packages = rec {
            default = nil;
            nil = pkgs.callPackage mkNil { };
            coc-nil = pkgs.callPackage mkCocNil { };
          };

          devShells.default = pkgs.mkShell {
            nativeBuildInputs = with pkgs; [
              # Override the stable rustfmt.
              rustPkgs.rust-nightly_2023-01-01.availableComponents.rustfmt
              # Follows nixpkgs's version of rustc.
              (let vers = lib.splitVersion rustc.version; in
                rustPkgs."rust_${lib.elemAt vers 0}_${lib.elemAt vers 1}_${lib.elemAt vers 2}")

              # Don't include `nix` by default. If would override user's (newer
              # or patched) one, cause damage or misbehavior due to version
              # mismatch.
              # If you do want a locked one, use `devShells.full` below.
              # nix.out

              nodejs

              jq
              pre-commit
              nixpkgs-fmt
              (import ./dev/nvim-lsp.nix { inherit pkgs; })
              (import ./dev/vim-coc.nix { inherit pkgs; })
              (import ./dev/vim-lsp.nix { inherit pkgs; })
            ] ++ lib.optionals (lib.meta.availableOn stdenv.hostPlatform vscodium) [
              (import ./dev/vscodium.nix { inherit pkgs; })
            ] ++ lib.optionals (lib.meta.availableOn stdenv.hostPlatform gdb) [
              gdb
            ];

            RUST_BACKTRACE = "short";
            NIXPKGS = nixpkgs;
            CLIPPY_FLAGS = clippyFlags;

            # bash
            shellHook = ''
              export NIL_PATH="$(cargo metadata --format-version=1 | jq -r .target_directory)/debug/nil"
              export COC_NIL_PATH="$(realpath ./editors/coc-nil)"
            '';
          };

          # See comments above.
          devShells.full = devShells.default.overrideAttrs (old: {
            nativeBuildInputs = old.nativeBuildInputs ++ [
              pkgs.nix.out
            ];
          });

          devShells.fuzz = pkgs.mkShell {
            packages = with pkgs; with rustPkgs; [
              rust-nightly_2022-08-01
              cargo-fuzz
              llvmPackages_14.llvm
              jq
              gnugrep
            ];
            RUST_BACKTRACE = "short";

            # bash
            shellHook = ''
              export CARGO_TARGET_DIR=~/.cache/targets-syntax
            '';
          };
        })
    // {
      overlays = {
        default = lib.composeExtensions self.overlays.nil self.overlays.coc-nil;
        nil = final: prev: {
          nil = final.callPackage mkNil { };
        };
        coc-nil = final: prev: {
          vimPlugins = prev.vimPlugins or { } // {
            coc-nil = final.callPackage mkCocNil { };
          };
        };
      };
    };
}
