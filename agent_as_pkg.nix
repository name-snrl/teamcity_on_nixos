input: { config, lib, pkgs, ... }:

with lib;

let
  stateDirs = [
    "temp"
    "logs"
    "work"
    "system"
    "tools"
    "backup"
    "update"
    "launcher/logs"
  ] ++ existedStateDirs;

  existedStateDirs = [ "plugins" "conf" ];

  additionalOutputs = map (builtins.replaceStrings ["/"] [""]) existedStateDirs;

  pkg = pkgs.stdenv.mkDerivation (input // {
    outputs = [ "out" ] ++ additionalOutputs;

    installPhase = ''
      ex=(${builtins.concatStringsSep " " existedStateDirs})

      for i in ''${ex[@]}; do
        dest=''${i/\//}
        mv buildAgent/$i ''${!dest}
      done

      cp -R buildAgent $out

      state=(${builtins.concatStringsSep " " stateDirs})

      for i in ''${state[@]}; do
        rm -rf $out/$i &> /dev/null
        ln -sf ${dataDir}/$i/ $out/
      done
    '';
  });

  dataDir = "/var/teamcity/agent";

  installer = pkgs.writeShellScriptBin "tc-agent" ''
    rm -rf ${dataDir}
    mkdir -p ${dataDir}/{${builtins.concatStringsSep "," stateDirs}}

    cp -rsfP ${pkg}/* ${dataDir}/

    ex=(${lib.concatMapStringsSep " " (p: p + "=${pkg.${p}}") additionalOutputs})

    for i in ''${ex[@]}; do
      dest=''${i%=*}
      source=''${i#*=}
      cp -rsfP $source/* ${dataDir}/$dest/
    done
  '';
in

{
  config = {
    environment.sessionVariables.JAVA_HOME = "${pkgs.jdk11_headless.home}";
    environment.systemPackages = [ pkg installer ];
  };
}
