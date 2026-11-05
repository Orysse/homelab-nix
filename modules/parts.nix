{ inputs, ... }:
{
  imports = [ inputs.flake-parts.flakeModules.modules inputs.den.flakeModule ];
  systems = [ "x86_64-linux" ];
}
