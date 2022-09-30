input: { config, lib, pkgs, ... }:

let
  name = "teamcity-server";
  cfg = config.services.teamcity;
  pkg = pkgs.stdenv.mkDerivation (input // {
    outputs = [ "out" "webapps" ];

    installPhase = ''
      runHook preInstall

      rm -rf licenses/ \
        devPackage/ \
        buildAgent/ \
        temp/ \
        bin/*.bat \
        bin/*.cmd \
        bin/*.exe \
        bin/runAll.sh \
        bin/teamcity-server-update.jar \
        bin/teamcity-update.sh \
        *.txt
      mkdir $out
      mv * $out
      mkdir -p $webapps/webapps
      mv $out/webapps $webapps/

      runHook postInstall
    '';
  });
in

{
  services.tomcat = {
    enable = true;
    jdk = pkgs.jdk11_headless;
    package = pkg;
    extraEnvironment = [
      "TEAMCITY_DATA_PATH=/var/teamcity"
    ];
    purifyOnStart = true;
  };
}
