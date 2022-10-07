input: { config, lib, pkgs, ... }:

with lib;

let
  name = "teamcity-agent";
  cfg = config.services.teamcity.agent;

  pkg = pkgs.stdenv.mkDerivation (input // {
    installPhase = "cp -R buildAgent $out";
  });
in

{
  options.services.teamcity.agent = with types; {

    enable = mkEnableOption name;

    user = mkOption {
      type = str;
      default = name;
      description = "User account under which ${name} runs.";
    };

    group = mkOption {
      type = str;
      default = name;
      description = "Group account under which ${name} runs.";
    };

    homeDir = mkOption {
      type = str;
      default = "${name}";
      apply = (o: "/var/lib/" + o);
      description = "Directory to be created by systemd in /var/lib.";
    };

    cleanUp = mkOption {
      type = either bool (listOf str);
      default = false;
      example = [ "work" "logs" ];
      description = ''
        If true, all data in ${cfg.homeDir} will be deleted. If list - delete all directories except for directories in list.
      '';
    };

    configuration = mkOption {
      type = attrsOf str;
      default = { };
      description = "Properties to pass to conf/buildAgent.properties.";
    };

    environment = mkOption {
      type = attrsOf str;
      default = { };
      example = {
        TEAMCITY_AGENT_MEM_OPTS = "Set agent memory options (JVM options)";
        TEAMCITY_AGENT_OPTS = "Set additional agent JVM options";
        TEAMCITY_LAUNCHER_MEM_OPTS = "Set agent launcher memory options (JVM options)";
        TEAMCITY_LAUNCHER_OPTS = "Set agent launcher JVM options";
      };
      description = "Defines environment variables.";
    };

    jdk = mkOption {
      type = package;
      default = pkgs.jdk11_headless;
      description = "Which JDK to use.";
    };

    plugins = mkOption {
      # check it
      type = listOf (either path package);
      default = [ ];
      description = "List containing path or package to be added to the plugins directory.";
    };

  };

  config = mkIf cfg.enable {

    users.users.${cfg.user} = {
      description = "${name} owner.";
      group = cfg.group;
      isSystemUser = true;
    };

    users.groups.${cfg.group} = { };

    systemd.services.${name} = {
      description = "TeamCity Build Agent";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      preStart = ''
        shopt -s extglob

        ${optionalString (cfg.cleanUp != false)
        (if (cfg.cleanUp == true) then "rm -rf ${cfg.homeDir}/*"
        else ''
          rm -rf ${cfg.homeDir}/!(${builtins.concatStringsSep "|" cfg.cleanUp})
        '')}

        cp -rf --no-preserve=mode ${pkg}/* ${cfg.homeDir}
        chmod +x ${cfg.homeDir}/bin/*.sh

        ${optionalString (builtins.isAttrs cfg.configuration) ''
          echo -e "\n${generators.toKeyValue { } cfg.configuration}"\
            >> ${cfg.homeDir}/conf/buildAgent.properties
        ''}

        ${optionalString (cfg.plugins != []) ''
          plugins=(${builtins.concatStringsSep " "
            (map (p: p.pname + "=" + (toString p) ) cfg.plugins)})

          for i in ''${plugins[@]}; do
            src=''${i#*=}
            dest=''${i%=*}
            mkdir -p ${cfg.homeDir}/plugins/$dest
            cp -rsf --no-preserve=mode $src/* ${cfg.homeDir}/plugins/$dest
          done
        ''}
      '';

      environment = {
        JAVA_HOME = "${cfg.jdk}";
      } // cfg.environment;

      path = [ pkgs.gawk ];

      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;

        Type = "oneshot";

        StateDirectory = removePrefix "/var/lib/" cfg.homeDir;
        StateDirectoryMode = "0700";

        ExecStart = "${cfg.homeDir}/bin/agent.sh start";
        ExecStop = "${cfg.homeDir}/bin/agent.sh stop";

        RemainAfterExit = true;
        SuccessExitStatus = "0 143";
      };
    };
  };
}
