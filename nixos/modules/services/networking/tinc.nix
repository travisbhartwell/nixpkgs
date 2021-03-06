{ config, lib, pkgs, ... }:

with lib;

let

  cfg = config.services.tinc;

in

{

  ###### interface

  options = {

    services.tinc = {

      networks = mkOption {
        default = { };
        type = types.loaOf types.optionSet;
        description = ''
          Defines the tinc networks which will be started.
          Each network invokes a different daemon.
        '';
        options = {

          extraConfig = mkOption {
            default = "";
            type = types.lines;
            description = ''
              Extra lines to add to the tinc service configuration file.
            '';
          };

          name = mkOption {
            default = null;
            type = types.nullOr types.str;
            description = ''
              The name of the node which is used as an identifier when communicating
              with the remote nodes in the mesh. If null then the hostname of the system
              is used.
            '';
          };

          debugLevel = mkOption {
            default = 0;
            type = types.addCheck types.int (l: l >= 0 && l <= 5);
            description = ''
              The amount of debugging information to add to the log. 0 means little
              logging while 5 is the most logging. <command>man tincd</command> for
              more details.
            '';
          };

          hosts = mkOption {
            default = { };
            type = types.loaOf types.lines;
            description = ''
              The name of the host in the network as well as the configuration for that host.
              This name should only contain alphanumerics and underscores.
            '';
          };

          interfaceType = mkOption {
            default = "tun";
            type = types.addCheck types.str (n: n == "tun" || n == "tap");
            description = ''
              The type of virtual interface used for the network connection
            '';
          };

          package = mkOption {
            default = pkgs.tinc_pre;
            description = ''
              The package to use for the tinc daemon's binary.
            '';
          };

        };
      };
    };

  };


  ###### implementation

  config = mkIf (cfg.networks != { }) {

    environment.etc = fold (a: b: a // b) { }
      (flip mapAttrsToList cfg.networks (network: data:
        flip mapAttrs' data.hosts (host: text: nameValuePair
          ("tinc/${network}/hosts/${host}")
          ({ mode = "0444"; inherit text; })
        ) // {
          "tinc/${network}/tinc.conf" = {
            mode = "0444";
            text = ''
              Name = ${if data.name == null then "$HOST" else data.name}
              DeviceType = ${data.interfaceType}
              Device = /dev/net/tun
              Interface = tinc.${network}
              ${data.extraConfig}
            '';
          };
        }
      ));

    networking.interfaces = flip mapAttrs' cfg.networks (network: data: nameValuePair
      ("tinc.${network}")
      ({
        virtual = true;
        virtualType = "${data.interfaceType}";
      })
    );

    systemd.services = flip mapAttrs' cfg.networks (network: data: nameValuePair
      ("tinc.${network}")
      ({
        description = "Tinc Daemon - ${network}";
        wantedBy = [ "network.target" ];
        after = [ "network-interfaces.target" ];
        path = [ data.package ];
        restartTriggers = [ config.environment.etc."tinc/${network}/tinc.conf".source ]
          ++ mapAttrsToList (host: _ : config.environment.etc."tinc/${network}/hosts/${host}".source) data.hosts;
        serviceConfig = {
          Type = "simple";
          PIDFile = "/run/tinc.${network}.pid";
        };
        preStart = ''
          mkdir -p /etc/tinc/${network}/hosts

          # Determine how we should generate our keys
          if type tinc >/dev/null 2>&1; then
            # Tinc 1.1+ uses the tinc helper application for key generation

            # Prefer ED25519 keys (only in 1.1+)
            [ -f "/etc/tinc/${network}/ed25519_key.priv" ] || tinc -n ${network} generate-ed25519-keys

            # Otherwise use RSA keys
            [ -f "/etc/tinc/${network}/rsa_key.priv" ] || tinc -n ${network} generate-rsa-keys 4096
          else
            # Tinc 1.0 uses the tincd application
            [ -f "/etc/tinc/${network}/rsa_key.priv" ] || tincd -n ${network} -K 4096
          fi
        '';
        script = ''
          tincd -D -U tinc.${network} -n ${network} --pidfile /run/tinc.${network}.pid -d ${toString data.debugLevel}
        '';
      })
    );

    users.extraUsers = flip mapAttrs' cfg.networks (network: _:
      nameValuePair ("tinc.${network}") ({
        description = "Tinc daemon user for ${network}";
        isSystemUser = true;
      })
    );

  };

}
