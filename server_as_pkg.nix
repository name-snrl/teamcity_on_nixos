input: { config, lib, pkgs, ... }:

with lib;

let
  stateDirs = [ "temp" "logs" "work" ] ++ existedStateDirs;

  existedStateDirs = [ "webapps" ];

  additionalOutputs = map (builtins.replaceStrings ["/"] [""]) existedStateDirs;

  pkg = pkgs.stdenv.mkDerivation (input // {
    outputs = [ "out" ] ++ additionalOutputs;

    buildPhase = ''
      shopt -s extglob
      rm -rf !("bin"|"conf"|"lib"|"webapps"|"service.properties")

      sed -E -i 's#<Resources?#& allowLinking="true" #' \
        webapps/ROOT/META-INF/context.xml
    '';

    installPhase = ''
      ex=(${builtins.concatStringsSep " " existedStateDirs})

      for i in ''${ex[@]}; do
        dest=''${i/\//}
        mv $i ''${!dest}
      done

      cp -R . $out

      state=(${builtins.concatStringsSep " " stateDirs})

      for i in ''${state[@]}; do
        rm -rf $out/$i &> /dev/null
        ln -sf ${dataDir}/$i/ $out/
      done
    '';
  });

  dataDir = "/var/teamcity/server";

  installer = pkgs.writeShellScriptBin "tc-server" ''
    rm -rf ${dataDir}
    mkdir -p ${dataDir}/{${builtins.concatStringsSep "," stateDirs}}

    #sed <Resources cachingAllowed="true" cacheMaxSize="20480" allowLinking="true" />

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
