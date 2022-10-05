input: { config, lib, pkgs, ... }:

with lib;

let
  pkg = pkgs.stdenv.mkDerivation (input // {
    installPhase = "cp -R buildAgent $out";
  });

  dataDir = "/var/teamcity/agent";

  installer = pkgs.writeShellScriptBin "tc-agent" ''
    rm -rf ${dataDir} && mkdir -p ${dataDir}/lib
    cp -rf ${pkg}/* ${dataDir}/
  '';
in

{
  config = {
    environment.sessionVariables.JAVA_HOME = "${pkgs.jdk11_headless.home}";
    environment.systemPackages = [ pkg installer ];
  };
}
