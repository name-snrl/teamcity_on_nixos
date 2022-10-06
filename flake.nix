{
  description = "TeamCity";

  inputs = {
    teamcity = {
      url = "https://download.jetbrains.com/teamcity/TeamCity-2022.04.4.tar.gz";
      flake = false;
    };
  };

  outputs = inputs@{ self, teamcity, ... }:
    {
      nixosModules = {
        teamcity-agent = import ./agent.nix {
          pname = "teamcity-agent";
          version = "22.04.4";
          src = teamcity;
        };
        teamcity-server = import ./server.nix {
          pname = "teamcity-server";
          version = "22.04.4";
          src = teamcity;
        };
        teamcity-server-as-pkg = import ./server_as_pkg.nix {
          pname = "teamcity-server";
          version = "22.04.4";
          src = teamcity;
        };
      };
    };
}
