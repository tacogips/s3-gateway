{
  description = "swift-s3-gateway Swift development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        lib = pkgs.lib;

        runtimePackages =
          with pkgs;
          [
            gh
            git
            go-task
            swiftlint
          ]
          ++ lib.optionals pkgs.stdenv.isLinux [
            swift
          ];

        devOnlyPackages = with pkgs; [
          gitleaks
        ];

        preCommitCheck = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            gitleaks = {
              enable = true;
              name = "gitleaks";
              entry = "${pkgs.lib.getExe pkgs.gitleaks} git --pre-commit --redact --staged --verbose";
              language = "system";
              pass_filenames = false;
            };
          };
        };

        devPackages = runtimePackages ++ devOnlyPackages ++ preCommitCheck.enabledPackages;
      in
      {
        packages.dev-tools = pkgs.buildEnv {
          name = "swift-s3-gateway-dev-tools";
          paths = devPackages;
          pathsToLink = [ "/bin" ];
        };

        checks.pre-commit-check = preCommitCheck;

        devShells.default = pkgs.mkShell {
          packages = devPackages;

          shellHook = ''
            ${preCommitCheck.shellHook}

            echo "swift-s3-gateway Swift development environment ready"
            echo "Swift version: $(swift --version 2>/dev/null | head -n 1 || echo 'not available')"
            echo "Task version: $(task --version 2>/dev/null || echo 'not available')"
            echo "SwiftLint version: $(swiftlint version 2>/dev/null || echo 'not available')"
            echo "Gitleaks version: $(gitleaks version 2>/dev/null || echo 'not available')"
          '';
        };
      }
    );
}
