input: { config, lib, pkgs, ... }:

let
  name = "teamcity-agent";
  cfg = config.services.teamcity.agent;
  pkg = pkgs.stdenv.mkDerivation (input // {
    installPhase = ''
      runHook preInstall

      cp -r buildAgent $out
      rm -rf bin/*.bat

      runHook postInstall
    '';
  });
in

{
  options.services.teamcity.agent = {

    enable = mkEnableOption name;

  };

  config = mkIf cfg.enable {

    systemd.services.${name} = {
      description = "${name} Service";
      wantedBy = [ "multi-user.target" ];
    };

  };
}
