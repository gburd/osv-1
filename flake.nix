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

        # Crucible distributed block storage from Oxide Computer
        # Using latest commit from main branch
        crucible = pkgs.rustPlatform.buildRustPackage rec {
          pname = "crucible";
          version = "unstable-2024-12-15";

          src = pkgs.fetchFromGitHub {
            owner = "oxidecomputer";
            repo = "crucible";
            rev = "main";  # Or specific commit
            sha256 = pkgs.lib.fakeSha256;  # Will fail first time, then use real hash
          };

          cargoLock = {
            lockFile = "${src}/Cargo.lock";
          };

          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.openssl ];

          # Build only the downstairs binary for testing
          cargoBuildFlags = [ "--bin" "crudd" "--bin" "crucible-downstairs" ];

          meta = with pkgs.lib; {
            description = "Distributed block storage system from Oxide Computer";
            homepage = "https://github.com/oxidecomputer/crucible";
            license = licenses.mpl20;
          };
        };

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

        # Boost headers for OSv build. boost::system became header-only in Boost 1.78
        # and libboost_system.a was removed in 1.78+. The OSv Makefile handles this
        # gracefully: it links the static library only if present, otherwise headers
        # suffice. We use the current Boost from nixpkgs (no version pin required).
        # nixpkgs splits boost into runtime (pkgs.boost) and headers (pkgs.boost.dev).
        boostHeaders = pkgs.boost.dev;

        boostHeadersAarch64 = pkgsAarch64.boost.dev;

        boostHeadersX86_64 = pkgsX86_64.boost.dev;

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
          firecracker
          gdb
          genromfs
          tcpdump
          pax-utils

          # Java toolchain (for tests and openjdk*-from-host modules)
          openjdk21
          maven
          ant

          # Python dependencies
          python3Packages.dpkt
          python3Packages.requests

          # Additional utilities
          curl
          wget
          unzip

          # For ca-certificates module (p11-kit extract builds Java/PEM trust stores)
          p11-kit
          nss
          nssTools
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
            boostHeaders
            boost  # runtime .so for linking (boost_filesystem etc.)
            libedit
            # OpenSSL 3.x for httpserver-api compilation (-lssl -lcrypto)
            openssl
            yaml-cpp
            # Lua 5.3 interpreter + headers for the lua module.
            # The binary is named 'lua' in nixpkgs; the module Makefile checks
            # 'command -v lua' to use the system copy instead of downloading.
            lua5_3
            # LuaRocks for installing Lua modules without a network download
            luarocks
          ]);

          shellHook = ''
            echo "OSv native development environment"
            echo "Build with: ./scripts/build"
            echo "Run with: ./scripts/run.py"
            echo "Test with: ./scripts/test.py"
            echo ""
            echo "Host architecture: ${system}"

            # Set boost path for OSv Makefile
            export boost_base="${boostHeaders}"

            # Set LIBCLANG_PATH for Rust bindgen
            export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"

            # ----------------------------------------------------------------
            # Nix compatibility: manifest_from_host.sh uses ldconfig -p which
            # returns nothing on NixOS.  Expose all needed .so paths via
            # LD_LIBRARY_PATH so the patched script can find them.
            # ----------------------------------------------------------------
            export LD_LIBRARY_PATH="${pkgs.openssl.out}/lib:${pkgs.boost.out}/lib:${pkgs.lua5_3}/lib:${pkgs.zlib.out}/lib:${pkgs.libedit}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            # Boost runtime lib dir for module Makefiles that link -lboost_filesystem etc.
            export boost_lib_dir="${pkgs.boost.out}/lib"

            # Java home for openjdk*-from-host module (packages JVM into image)
            export JAVA_HOME="${pkgs.openjdk21}"
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
            boostHeadersAarch64
            pkgsAarch64.libedit
            pkgsAarch64.openssl
            pkgsAarch64.yaml-cpp
            pkgsAarch64.lua5_3
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
            export boost_base="${boostHeadersAarch64}"
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
            boostHeadersX86_64
            pkgsX86_64.libedit
            pkgsX86_64.openssl
            pkgsX86_64.yaml-cpp
            pkgsX86_64.lua5_3
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
            export boost_base="${boostHeadersX86_64}"
          '';

          OSV_ROOT = builtins.toString ./.;
          PYTHONPATH = "${pkgs.python3Packages.dpkt}/lib/python${pkgs.python3.pythonVersion}/site-packages:${pkgs.python3Packages.requests}/lib/python${pkgs.python3.pythonVersion}/site-packages";
        };

        # Provide formatter for `nix fmt`
        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
