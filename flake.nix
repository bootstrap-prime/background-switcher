{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = inputs@{ self, flake-utils, nixpkgs, rust-overlay, crane
    , advisory-db, ... }:
    flake-utils.lib.eachSystem [ flake-utils.lib.system.x86_64-linux ] (system:
      let
        overlays = [ (import rust-overlay) ];
        pkgs = import nixpkgs { inherit system overlays; };

        rust-custom-toolchain = (pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-src" "rustfmt" "rust-analyzer-preview" ];
        });

        craneLib =
          (inputs.crane.mkLib pkgs).overrideToolchain rust-custom-toolchain;
      in rec {
        devShell = pkgs.mkShell {
          nativeBuildInputs = with pkgs; [
            # get current rust toolchain defaults (this includes clippy and rustfmt)
            rust-custom-toolchain

            cargo-edit
          ];

          # fetch with cli instead of native
          CARGO_NET_GIT_FETCH_WITH_CLI = "true";
          RUST_BACKTRACE = 1;
        };

        packages.default = craneLib.buildPackage { src = ./.; };
        packages.rofi-switcher = pkgs.writeScriptBin "rofi-background" ''
          ${pkgs.rofi}/bin/rofi -show background -modes "background:${self.packages.${system}.default}/bin/background-switcher"
        '';

        checks = let
          craneLib =
            (inputs.crane.mkLib pkgs).overrideToolchain rust-custom-toolchain;
          src = ./.;

          cargoArtifacts = craneLib.buildDepsOnly { inherit src; };
          build-tests = craneLib.buildPackage { inherit cargoArtifacts src; };
        in {
          inherit build-tests;

          # Run clippy (and deny all warnings) on the crate source,
          # again, reusing the dependency artifacts from above.
          #
          # Note that this is done as a separate derivation so that
          # we can block the CI if there are issues here, but not
          # prevent downstream consumers from building our crate by itself.
          my-crate-clippy = craneLib.cargoClippy {
            inherit cargoArtifacts src;
            cargoClippyExtraArgs = "-- --deny warnings";
          };

          # Check formatting
          my-crate-fmt = craneLib.cargoFmt { inherit src; };

          # Audit dependencies
          my-crate-audit = craneLib.cargoAudit {
            inherit src;
            advisory-db = inputs.advisory-db;
            cargoAuditExtraArgs = "--ignore RUSTSEC-2020-0071";
          };

          # Run tests with cargo-nextest
          my-crate-nextest = craneLib.cargoNextest {
            inherit cargoArtifacts src;
            partitions = 1;
            partitionType = "count";
          };
        };
      });
}
