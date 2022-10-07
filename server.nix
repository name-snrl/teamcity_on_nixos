input: { config, lib, pkgs, ... }:

with lib;

let
  name = "teamcity-server";
  cfg = config.services.teamcity;

  existedStateDirs = [ "webapps" ];

  stateDirs = [ "temp" "logs" "work" ] ++ existedStateDirs;

  additionalOutputs = map (builtins.replaceStrings [ "/" ] [ "" ]) existedStateDirs;

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
        ln -sf ${cfg.homeDir}/$i/ $out/
      done
    '';
  });

  preStart = ''
    set +e

    ### Stage 0. Clean-up
    ${optionalString (cfg.cleanUp != false)
    (if (cfg.cleanUp == true) then "rm -rf ${cfg.homeDir}/*"
    else ''
      rm -rf ${cfg.homeDir}/{${builtins.concatStringsSep "," cfg.cleanUp}}
    '')}

    ### Stage 1. Install
    mkdir -p ${cfg.homeDir}/{${builtins.concatStringsSep "," stateDirs}}

    cp -rsf --no-preserve=mode ${pkg}/* ${cfg.homeDir}/ &> /dev/null

    ex=(${lib.concatMapStringsSep " " (p: p + "=${pkg.${p}}") additionalOutputs})

    for i in ''${ex[@]}; do
      dest=''${i%=*}
      source=''${i#*=}
      cp -rsf --no-preserve=mode $source/* ${cfg.homeDir}/$dest/ &> /dev/null
    done

    ### Stage 2. Override

    rm -rf ${cfg.homeDir}/webapps/ROOT/update/buildAgent.zip
    cp -rf ${pkg.webapps}/ROOT/update/buildAgent.zip \
      ${cfg.homeDir}/webapps/ROOT/update/buildAgent.zip

  '';
    #${optionalString cfg.serverXml ''
    #  sed -E -i 's#<Server #& allowLinking="true" #' \
    #    ${cfg.homeDir}/conf/server.xml

    #    sed -e 's,port="8090",port="${toString cfg.listenPort}" address="${cfg.listenAddress}",' \
    #    '' + (lib.optionalString cfg.proxy.enable ''
    #      -e 's,protocol="org.apache.coyote.http11.Http11NioProtocol",protocol="org.apache.coyote.http11.Http11NioProtocol" proxyName="${cfg.proxy.name}" proxyPort="${toString cfg.proxy.port}" scheme="${cfg.proxy.scheme}",' \
    #    '') + ''
    #      ${pkg}/conf/server.xml.dist > ${cfg.homeDir}/conf/server.xml
    #'' }
    #${optionalString (builtins.isAttrs cfg.configuration) ''
    #  echo -e "\n${generators.toKeyValue { } cfg.configuration}"\
    #    >> ${cfg.dataDir}/config/teamcity-startup.properties
    #''}

in

{
  options.services.teamcity = with types; {

    enable = mkEnableOption name; # rdy

    user = mkOption { # rdy
      type = str;
      default = name;
      description = "User account under which ${name} runs.";
    };

    group = mkOption { # rdy
      type = str;
      default = name;
      description = "Group account under which ${name} runs. Add user to this group to get access to Data Directory.";
    };

    homeDir = mkOption { # rdy
      type = str;
      default = "${name}";
      apply = (o: "/var/lib/" + o);
      description = "Agent's Home Directory will be created by systemd in /var/lib.";
    };

    #homeConfigs = mkOption {
    #  default = {
    #  append = {};
    #  override = {};
    #  };
    #  type = types.listOf types.path;
    #  description = lib.mdDoc "Extra configuration files to pull into the tomcat conf directory";
    #};

    dataDir = mkOption { # rdy
      type = str;
      default = "/${name}";
      description = "Path to TeamCity Data Directory.";
    };

    #dataConfigs = mkOption {
    #  default = {
    #  append = {};
    #  override = {};
    #  };
    #  type = types.listOf types.path;
    #  description = lib.mdDoc "Extra configuration files to pull into the tomcat conf directory";
    #};

    cleanUp = mkOption {
      type = either bool (listOf str);
      default = false;
      example = [ "work" "logs" ];
      description = ''
        If true, all data in ${cfg.homeDir} will be deleted. Also you can remove
        certain directories in ${cfg.homeDir}.
      '';
    };

    listenAddress = mkOption {
      type = str;
      default = "localhost";
      description = "Address the server will listen on.";
    };

    port = mkOption {
      type = port;
      default = 8111;
      description = "Port the server will listen on.";
    };

    environment = mkOption { # rdy
      type = attrsOf str;
      default = { };
      example = {
        TEAMCITY_SERVER_MEM_OPTS = "server memory options (JVM options)";
        TEAMCITY_SERVER_OPTS = "additional server JVM options";
        TEAMCITY_LOGS_PATH = "path to TeamCity logs directory";
        TEAMCITY_RESTART_LIMIT = "number of restart attempts on unexpected server exit (e.g. JVM crash), default is 3";
      };
      description = "Defines environment variables.";
    };

    jdk = mkOption { # rdy
      type = package;
      default = pkgs.jdk11_headless;
      description = "Which JDK to use.";
    };

    # HOW TO

    #virtualHost = mkOption {
    #  # and HERE !!!!!!!!!
    #  type = types.submodule (import ../web-servers/apache-httpd/vhost-options.nix);
    #  example = literalExpression ''
    #    {
    #      hostName = "mediawiki.example.org";
    #      adminAddr = "webmaster@example.org";
    #      forceSSL = true;
    #      enableACME = true;
    #    }
    #  '';
    #  description = lib.mdDoc ''
    #    Apache configuration can be done by adapting {option}`services.httpd.virtualHosts`.
    #    See [](#opt-services.httpd.virtualHosts) for further information.
    #  '';
    #};

    nginx.enable = mkEnableOption "proxy";
    nginx.ssl.enable = mkEnableOption "ssl";

  };

  ### implementation

  config =
    let
      nginx = mkIf cfg.nginx.enable {

        # WIP
        services.nginx = {
          enable = true;
          clientMaxBodySize = "0";
          virtualHosts."vm.local" = { # opt
            extraConfig = ''
              proxy_read_timeout     1200;
              proxy_connect_timeout  240;
            '';
            locations."/" = {
              proxyPass = "http://localhost:8111"; # opt
              proxyWebsockets = true;
              extraConfig = ''
                proxy_set_header    Host $server_name:$server_port;
                proxy_set_header    X-Forwarded-Host $http_host;
                proxy_set_header    X-Forwarded-Proto $scheme;
                proxy_set_header    X-Forwarded-For $remote_addr;
              '';
            };
          };
        };

      };

      ssl = mkIf (cfg.nginx.ssl.enable && cfg.nginx.enable) {

        # WIP
        services.nginx.virtualHosts."vm.local" = { # opt
          addSSL = true;
          enableACME = true;
        };
        security.acme = {
          acceptTerms = true;
          defaults.email = "mail@mail.org"; # opt
        };

      };

      # rdy
      main = {

        environment.systemPackages = [
          (pkgs.writeShellScriptBin "teamcity-maintainDB" ''
            export JAVA_HOME="${cfg.jdk}";
            export TEAMCITY_DATA_PATH="${cfg.dataDir}";
            exec ${cfg.homeDir}/bin/maintainDB.sh $*
          '')
        ];

        users.users.${cfg.user} = {
          description = "${name} owner.";
          group = cfg.group;
          isSystemUser = true;
          createHome = true;
          home = cfg.dataDir;
          homeMode = "750";
        };

        users.groups.${cfg.group} = { };

        systemd.services.${name} = {
          description = name;
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];

          preStart = preStart;

          environment = {
            JAVA_HOME = "${cfg.jdk}";
            TEAMCITY_DATA_PATH = "${cfg.dataDir}";
            TEAMCITY_PID_FILE_PATH = "/run/${name}/${name}.pid";
            CATALINA_PID = "/run/${name}/${name}.pid";
          } // cfg.environment;

          path = with pkgs; [ bash gawk ps ];

          serviceConfig = {
            User = cfg.user;
            Group = cfg.group;

            Type = "forking";
            PIDFile = "/run/${name}/${name}.pid";

            RuntimeDirectory = name;
            StateDirectory = removePrefix "/var/lib/" cfg.homeDir;
            StateDirectoryMode = "0700";

            ExecStart = "${pkg}/bin/teamcity-server.sh start";
            ExecStop = "${pkg}/bin/teamcity-server.sh stop";
          };
        };

      };

    in
    mkIf cfg.enable (mkMerge [
      main
      nginx
      ssl
    ]);
}
