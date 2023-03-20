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
        packages.rofi-switcher = let
          # switcher = pkgs.writeScriptBin "background-switcher.sh" ''
          #   #!/usr/bin/env bash
          #   if [[ x"$@" = x"quit" ]]
          #   then
          #       exit 0
          #   fi

          #   if [[ ! $# -eq 0 ]]
          #   then
          #       echo "$@" | ${pkgs.socat}/bin/socat - unix-connect:/tmp/background-switcher.socket

          #       # $@ = "quit"
          #       exit 0
          #   fi

          #   echo "quit"
          #   echo "query" | ${pkgs.socat}/bin/socat - unix-connect:/tmp/background-switcher.socket

          # '';
        in pkgs.writeScriptBin "rofi-background" ''
          ${pkgs.rofi}/bin/rofi -show background -modes "background:${self.packages.${system}.default}/bin/background-switcher"
        '';
          # ${
          #   switcher
          # }/bin/background-switcher.sh"

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

        nixosModules."background-switcher" = { config, lib, ... }:
          let cfg = config.services.background-switcher;
          in {
            options = {
              services.background-switcher = {
                enable = lib.mkEnableOption
                  "a userspace background controller service.";
              };
            };

            config = lib.mkIf cfg.enable {
              systemd.user.sockets."background-switcher" = {
                Unit = { PartOf = "background-switcher.service"; };
                Socket = {
                  Accept = "yes";
                  ListenStream =
                    "/tmp/background-switcher.socket"; # ListenStream = "/tmp/background-switcher.socket";
                };
                Install = { WantedBy = [ "sockets.target" ]; };
              };

              systemd.user.services."background-switcher@" = {
                Unit = {
                  Description = "A userspace background controller service.";
                  Requires = [ "background-switcher.socket" ];
                };

                # Install = {
                #   WantedBy = [ "multi-user.target" ];
                # };

                Service = {
                  Type = "simple";
                  Sockets = "background-switcher.socket";

                  ExecStart = ''
                    ${pkgs.bash}/bin/bash -c "PATH=${pkgs.feh}/bin/ exec ${
                      self.packages.${system}.default
                    }/bin/background-switcher"'';
                  StandardInput = "socket";
                  StandardOutput = "socket";
                  StandardError = "journal";
                  Environment = "PATH=${pkgs.feh}/bin/feh";
                };
              };
            };
          };
      });
}
