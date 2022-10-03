input: { config, lib, pkgs, ... }:

with lib;

let
  stateDirs = [
    "temp"
    "logs"
    "work"
    "virtualhosts"
  ];

  dataDir = "/var/teamcity/server";

  pkg = pkgs.stdenv.mkDerivation (input // {

    buildPhase = ''
      shopt -s extglob
      rm -rf !("bin"|"conf"|"lib"|"webapps"|"service.properties")
    '';

    installPhase = ''
      cp -R . $out

      state=(${builtins.concatStringsSep " " stateDirs})

      for i in "''${state[@]}"; do
        ln -sf ${dataDir}/$i/ $out/
      done
    '';
  });

  installer = pkgs.writeShellScriptBin "install-tc-server" ''
    rm -rf ${dataDir}
    echo --- BEFORE ---
    ${pkgs.exa}/bin/exa -la ${pkg}
    mkdir -p ${dataDir}/{${builtins.concatStringsSep "," stateDirs}}
    cp -rsf ${pkg}/* ${dataDir}/ &> /dev/null
    cp --remove-destination ${pkg}/bin/*.sh ${dataDir}/bin/
    echo --- AFTER ---
    ${pkgs.exa}/bin/exa -la ${pkg}
  '';
in

{
  config = {
    environment.sessionVariables.JAVA_HOME = "${pkgs.jdk11_headless.home}";
    environment.systemPackages = [ pkg installer ];
  };
}
