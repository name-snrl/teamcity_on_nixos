input: { config, lib, pkgs, modulesPath, ... }:

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
    shopt -s extglob

    ### Stage 0. Clean-up
    ${optionalString (cfg.cleanUp != false)
        (if (cfg.cleanUp == true) then "rm -rf ${cfg.homeDir}/*"
        else ''
      rm -rf ${cfg.homeDir}/!(${builtins.concatStringsSep "|" cfg.cleanUp})
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

    # server.xml
    rm -f ${cfg.homeDir}/conf/server.xml
    cp -f --no-preserve=mode ${pkg}/conf/server.xml ${cfg.homeDir}/conf/server.xml
    ${if cfg.reverseProxy.enable then (if cfg.reverseProxy.enableACME
        then ''
      ${pkgs.yq-go}/bin/yq -p xml -o xml 'del(.Server.Service.Connector) |= {
      "+port": "8111",
      "+protocol": "org.apache.coyote.http11.Http11NioProtocol",
      "+connectionTimeout": "60000", 
      "+useBodyEncodingForURI": true, 
      "+socket.txBufSize": "64000", 
      "+socket.rxBufSize": "64000", 
      "+tcpNoDelay": "1", 
      "+secure": true, 
      "+scheme": "https"}' ${pkg}/conf/server.xml > ${cfg.homeDir}/conf/server.xml
    '' else ''
      ${pkgs.yq-go}/bin/yq -p xml -o xml 'del(.Server.Service.Connector) |= {
      "+port": "8111",
      "+protocol": "org.apache.coyote.http11.Http11NioProtocol",
      "+connectionTimeout": "60000", 
      "+useBodyEncodingForURI": true, 
      "+socket.txBufSize": "64000", 
      "+socket.rxBufSize": "64000", 
      "+tcpNoDelay": "1", 
      "+secure": false, 
      "+scheme": "http"}' ${pkg}/conf/server.xml > ${cfg.homeDir}/conf/server.xml
    '') else ''
      ${pkgs.yq-go}/bin/yq -p xml -o xml '.Server.Service.Connector +=
        {"+port": "${toString cfg.port}", "+address": "${cfg.listenAddress}"}' \
        ${pkg}/conf/server.xml > ${cfg.homeDir}/conf/server.xml
    ''}


  '';

in

{
  options.services.teamcity = with types; {

    enable = mkEnableOption name;

    user = mkOption {
      type = str;
      default = name;
      description = "User account under which ${name} runs.";
    };

    group = mkOption {
      type = str;
      default = name;
      description = "Group account under which ${name} runs. Add user to this group to get access to Data Directory.";
    };

    homeDir = mkOption {
      type = str;
      default = "${name}";
      apply = (o: "/var/lib/" + o);
      description = "Agent's Home Directory will be created by systemd in /var/lib.";
    };

    dataDir = mkOption {
      type = str;
      default = "/${name}";
      description = "Path to TeamCity Data Directory.";
    };

    cleanUp = mkOption {
      type = either bool (listOf str);
      default = false;
      example = [ "work" "logs" ];
      description = ''
        If true, all data in ${cfg.homeDir} will be deleted. If list - delete all directories except for directories in list.
      '';
    };

    listenAddress = mkOption {
      type = str;
      default = "localhost";
      description = "Address the tomcat/nginx will listen on.";
    };

    port = mkOption {
      type = port;
      default = 8111;
      description = "Port the ${name} will listen on. This has no effect on the nginx proxy.";
    };

    environment = mkOption {
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

    jdk = mkOption {
      type = package;
      default = pkgs.jdk11_headless;
      description = "Which JDK to use.";
    };

    reverseProxy.enable = mkEnableOption "Nginx reverse proxy";
    reverseProxy.enableACME = mkEnableOption "Nginx SSL";

  };

  ### implementation

  config =
    let

      ssl = mkIf (cfg.reverseProxy.enableACME && cfg.reverseProxy.enable) {
        services.nginx.virtualHosts.${cfg.listenAddress} = {
          forceSSL = true;
          enableACME = true;
        };
      };

      proxy = {
        services.nginx = mkIf cfg.reverseProxy.enable {
          enable = true;
          virtualHosts.${cfg.listenAddress} = {
            extraConfig = ''
              proxy_read_timeout     1200;
              proxy_connect_timeout  240;
              client_max_body_size   0;
            '';
            locations."/" = {
              proxyPass = "http://localhost:8111";
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
    mkIf cfg.enable (mkMerge [ main proxy ssl ]);
}
