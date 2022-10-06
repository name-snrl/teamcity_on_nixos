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
    rm -rf ${cfg.homeDir}/*
    mkdir -p ${cfg.homeDir}/{${builtins.concatStringsSep "," stateDirs}}

    #sed <Resources cachingAllowed="true" cacheMaxSize="20480" allowLinking="true" />

    cp -rsf --no-preserve=mode ${pkg}/* ${cfg.homeDir}/ &> /dev/null

    ex=(${lib.concatMapStringsSep " " (p: p + "=${pkg.${p}}") additionalOutputs})

    for i in ''${ex[@]}; do
      dest=''${i%=*}
      source=''${i#*=}
      cp -rsf --no-preserve=mode $source/* ${cfg.homeDir}/$dest/ &> /dev/null
    done

    # override with regular file
    rm -rf ${cfg.homeDir}/webapps/ROOT/update/buildAgent.zip
    cp -rf ${pkg.webapps}/ROOT/update/buildAgent.zip \
      ${cfg.homeDir}/webapps/ROOT/update/buildAgent.zip


    # tests
    touch ${cfg.dataDir}/test
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
      description = "Group account under which ${name} runs.";
    };

    homeDir = mkOption {
      type = str;
      default = "${name}";
      apply = (o: "/var/lib/" + o);
      description = "Directory to be created by systemd in /var/lib.";
    };

    dataDir = mkOption {
      type = str;
      default = "/${name}";
      description = "Full path to data teamcity directory that contain";
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


    nginx.enable = mkEnableOption "proxy";



    ### mb we need this

    extraConfigFiles = mkOption {
      default = [];
      type = types.listOf types.path;
      description = lib.mdDoc "Extra configuration files to pull into the tomcat conf directory";
    };

    extraGroups = mkOption {
      default = [];
      type = types.listOf types.str;
      example = [ "users" ];
      description = lib.mdDoc "Defines extra groups to which the tomcat user belongs.";
    };

    serverXml = mkOption {
      type = types.lines;
      default = "";
      description = lib.mdDoc ''
        Verbatim server.xml configuration.
        This is mutually exclusive with the virtualHosts options.
      '';
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

    #virtualHost = mkOption {
    #  type = types.submodule (import ../web-servers/apache-httpd/vhost-options.nix);
    #  example = literalExpression ''
    #    { hostName = "example.org";
    #      adminAddr = "webmaster@example.org";
    #      enableSSL = true;
    #      sslServerCert = "/var/lib/acme/example.org/full.pem";
    #      sslServerKey = "/var/lib/acme/example.org/key.pem";
    #    }
    #  '';
    #};

    #services.httpd = {
    #  enable = true;
    #  adminAddr = mkDefault cfg.virtualHost.adminAddr;
    #  extraModules = [ "proxy_fcgi" ];

    #  # look here            !!!!
    #  virtualHosts.${cfg.virtualHost.hostName} = mkMerge [
    #    cfg.virtualHost
    #    {

    #      documentRoot = mkForce "${cfg.package}/share/moodle";
    #      extraConfig = ''
    #        <Directory "${cfg.package}/share/moodle">
    #          <FilesMatch "\.php$">
    #            <If "-f %{REQUEST_FILENAME}">
    #              SetHandler "proxy:unix:${fpm.socket}|fcgi://localhost/"
    #            </If>
    #          </FilesMatch>
    #          Options -Indexes
    #          DirectoryIndex index.php
    #        </Directory>
    #      '';
    #    }
    #  ];
    #};

  };

  config = mkIf cfg.enable {

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
        #addSSL = mkIf cfg.nginx.ssl.enable true;
        #enableACME = mkIf cfg.nginx.ssl.enable true;
      };
    };
    #security.acme = mkIf cfg.nginx.ssl.enable {
    #  acceptTerms = true;
    #  default.email = "mail@mail.org"; # opt
    #};

    users.users.${cfg.user} = {
      description = "${name} owner.";
      group = cfg.group;
      isSystemUser = true;
      createHome = true;
      home = cfg.dataDir;
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
        PIDFile="/run/${name}/${name}.pid";

        RuntimeDirectory = name;
        StateDirectory = removePrefix "/var/lib/" cfg.homeDir;

        ExecStart = "${pkg}/bin/teamcity-server.sh start";
        ExecStop = "${pkg}/bin/teamcity-server.sh stop";
      };
    };

  };
}
