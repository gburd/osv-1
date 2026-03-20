{
  description = "OSv - Unikernel Operating System with cross-compilation support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Cross-compilation package sets
        pkgsAarch64 = import nixpkgs {
          inherit system;
          crossSystem = {
            config = "aarch64-unknown-linux-gnu";
          };
        };

        pkgsX86_64 = import nixpkgs {
          inherit system;
          crossSystem = {
            config = "x86_64-unknown-linux-gnu";
          };
        };

        # Use boost 1.77 - last version before boost::system became header-only
        # OSv requires libboost_system.a which was removed in later versions
        boostStatic = pkgs.boost177.override {
          enableStatic = true;
          enableShared = false;
        };

        boostStaticAarch64 = pkgsAarch64.boost177.override {
          enableStatic = true;
          enableShared = false;
        };

        boostStaticX86_64 = pkgsX86_64.boost177.override {
          enableStatic = true;
          enableShared = false;
        };

        # Common build inputs for all shells
        commonBuildInputs = with pkgs; [
          # Core build tools
          gnumake
          python3
          autoconf
          automake
          libtool
          patch
          bison
          flex
          git

          # Development tools
          qemu
          gdb
          genromfs
          tcpdump
          pax-utils

          # Java toolchain (for tests)
          openjdk17
          maven
          ant

          # Python dependencies
          python3Packages.dpkt
          python3Packages.requests

          # Additional utilities
          curl
          wget
          unzip
        ];

      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = commonBuildInputs ++ (with pkgs; [
            # Native toolchain
            gcc

            # Rust toolchain for Crucible driver
            cargo
            rustc
            rustfmt
            clippy

            # Required for Rust bindgen
            clang
            llvmPackages.libclang.lib

            # Required libraries (native)
            boostStatic
            libedit
            openssl
            yaml-cpp
            lua5_4
          ]);

          shellHook = ''
            echo "OSv native development environment"
            echo "Build with: ./scripts/build"
            echo "Run with: ./scripts/run.py"
            echo "Test with: ./scripts/test.py"
            echo ""
            echo "Host architecture: ${system}"

            # Set boost path for OSv Makefile
            export boost_base="${boostStatic}"

            # Set LIBCLANG_PATH for Rust bindgen
            export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
          '';

          # Environment variables
          OSV_ROOT = builtins.toString ./.;

          # Ensure Python can find required modules
          PYTHONPATH = "${pkgs.python3Packages.dpkt}/lib/python${pkgs.python3.pythonVersion}/site-packages:${pkgs.python3Packages.requests}/lib/python${pkgs.python3.pythonVersion}/site-packages";
        };

        # Cross-compilation shell for x86_64 -> aarch64
        crossAarch64 = pkgs.mkShell {
          nativeBuildInputs = commonBuildInputs ++ (with pkgs; [
            # Cross-compilation toolchain
            pkgsCross.aarch64-multiplatform.buildPackages.gcc
            pkgsCross.aarch64-multiplatform.buildPackages.binutils
          ]) ++ [
            # Target architecture libraries
            boostStaticAarch64
            pkgsAarch64.libedit
            pkgsAarch64.openssl
            pkgsAarch64.yaml-cpp
            pkgsAarch64.lua5_4
          ];

          shellHook = ''
            echo "OSv cross-compilation environment: ${system} -> aarch64"
            echo "Build with: ./scripts/build arch=aarch64"
            echo "Test with: qemu-system-aarch64 ..."
            echo ""
            echo "Cross-compilation configured for aarch64 target"

            # Set cross-compilation environment
            export CROSS_PREFIX=aarch64-linux-gnu-
            export ARCH=aarch64

            # Set boost path for target architecture
            export boost_base="${boostStaticAarch64}"
          '';

          OSV_ROOT = builtins.toString ./.;
          PYTHONPATH = "${pkgs.python3Packages.dpkt}/lib/python${pkgs.python3.pythonVersion}/site-packages:${pkgs.python3Packages.requests}/lib/python${pkgs.python3.pythonVersion}/site-packages";
        };

        # Cross-compilation shell for aarch64 -> x86_64
        crossX86_64 = pkgs.mkShell {
          nativeBuildInputs = commonBuildInputs ++ (with pkgs; [
            # Cross-compilation toolchain
            pkgsCross.gnu64.buildPackages.gcc
            pkgsCross.gnu64.buildPackages.binutils
          ]) ++ [
            # Target architecture libraries
            boostStaticX86_64
            pkgsX86_64.libedit
            pkgsX86_64.openssl
            pkgsX86_64.yaml-cpp
            pkgsX86_64.lua5_4
          ];

          shellHook = ''
            echo "OSv cross-compilation environment: ${system} -> x86_64"
            echo "Build with: ./scripts/build arch=x64"
            echo "Test with: qemu-system-x86_64 ..."
            echo ""
            echo "Cross-compilation configured for x86_64 target"

            # Set cross-compilation environment
            export CROSS_PREFIX=x86_64-linux-gnu-
            export ARCH=x64

            # Set boost path for target architecture
            export boost_base="${boostStaticX86_64}"
          '';

          OSV_ROOT = builtins.toString ./.;
          PYTHONPATH = "${pkgs.python3Packages.dpkt}/lib/python${pkgs.python3.pythonVersion}/site-packages:${pkgs.python3Packages.requests}/lib/python${pkgs.python3.pythonVersion}/site-packages";
        };

        # Provide formatter for `nix fmt`
        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
