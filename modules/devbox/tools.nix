# Tools on the devbox's PATH: the owner's tmux and nvim (config flake), the dev basics and the
# coding agents. The shell (zsh) is set up in guest.nix.
{ config, inputs, lib, ... }:
let
  # claude-code is the only unfree package on the box.
  allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
in
{
  flake.modules.nixos.devbox-tools = { lib, pkgs, ... }:
    let
      owner = inputs.config.packages.${pkgs.stdenv.hostPlatform.system};
      # The guest reuses nuc1's package set (microvm.vms.<n>.pkgs), where `nixpkgs.config`
      # is refused by an assertion. A second instance of the same nixpkgs carries the
      # predicate and is used for claude-code only, so nuc1 itself stays free-only.
      unfreePkgs = import pkgs.path {
        inherit (pkgs.stdenv.hostPlatform) system;
        config = { inherit allowUnfreePredicate; };
      };
    in
    {
      environment.systemPackages = [
        owner.tmux
        owner.nvim
        # `vim` runs the owner's nvim; hiPrio because host/base.nix also installs real vim.
        (lib.hiPrio (pkgs.writeShellScriptBin "vim" ''exec ${lib.getExe owner.nvim} "$@"''))
        pkgs.git
        unfreePkgs.claude-code
        pkgs.opencode
        pkgs.ripgrep
        pkgs.fzf
        pkgs.jq
        pkgs.openbao
        pkgs.curl
      ];
    };

  # Builds the guest toplevel and looks for each binary in sw/bin; the unfree predicate must
  # allow claude-code and nothing else.
  perSystem = { pkgs, ... }: {
    checks.devbox-tools =
      let
        guest = config.flake.nixosConfigurations.nuc1.config.microvm.vms.devbox.config.config;
        binaries = [ "tmux" "nvim" "vim" "git" "zsh" "claude" "opencode" "rg" "fzf" "jq" "bao" "curl" ];
      in
      assert allowUnfreePredicate { pname = "claude-code"; };
      assert !(allowUnfreePredicate { pname = "something-else"; });
      assert guest.users.users.abel.shell.pname == "zsh";
      pkgs.runCommand "devbox-tools" { } ''
        for b in ${lib.escapeShellArgs binaries}; do
          test -e ${guest.system.build.toplevel}/sw/bin/$b || { echo "missing in sw/bin: $b"; exit 1; }
        done
        touch $out
      '';
  };
}
