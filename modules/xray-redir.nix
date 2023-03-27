{ config, pkgs, lib, ... }:

with pkgs;
with lib;
let
  cfg = config.services.xray-redir;
  recursiveMerge = sets:
    zipAttrsWith (name: values:
      if all isList values then
        concatLists values
      else if all isAttrs values then
        recursiveMerge values
      else
        last values) sets;
in {
  options = with types; {
    services.xray-redir = {
      enable = mkOption {
        type = bool;
        default = false;
      };
      host = mkOption { type = str; };
      port = mkOption { type = int; };
      user = mkOption { type = str; };
      dns = mkOption { type = listOf str; };
      ignores = mkOption {
        type = listOf str;
        default = [ ];
      };
      extraConfig = mkOption {
        type = attrs;
        default = { };
      };
    };
  };
  config = let
    china-ip-list = stdenv.mkDerivation {
      name = "china-ip-list";
      src = fetchFromGitHub {
        owner = "17mon";
        repo = "china_ip_list";
        rev = "78c3d7855678f058e5ca861e0a28aa9800dba308";
        hash = "sha256-wAymDtFKLzxudF+ypo5qtpO4GdGWw0cRo/7xYq2nHoU=";
      };
      installPhase = ''
        mkdir -p $out
        cp china_ip_list.txt $out/ignore.list
        cat <<EOF >> $out/ignore.list
        10.0.0.0/8
        100.64.0.0/10
        127.0.0.0/8
        169.254.0.0/16
        172.16.0.0/12
        192.0.0.0/24
        192.168.0.0/16
        224.0.0.0/4
        240.0.0.0/4
        255.255.255.255/32
        EOF
        cat <<EOF >> $out/ignore.list
        ${strings.concatStringsSep "\n" cfg.ignores}
        EOF
      '';
    };
  in mkIf cfg.enable {
    systemd.services.ipset = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      path = [ ipset china-ip-list ];
      script = ''
        ipset create ignore hash:net
        for ip in `cat ${china-ip-list}/ignore.list`; do
            ipset add ignore $ip
        done
      '';
      preStop = "ipset destroy ignore";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };
    };
    systemd.services.xray = let
      basicConfig = {
        inbounds = [{
          port = 1024;
          protocol = "dokodemo-door";
          settings = {
            network = "tcp,udp";
            followRedirect = true;
          };
          streamSettings = { sockopt = { tproxy = "tproxy"; }; };
        }];
        outbounds = [{
          protocol = "vless";
          settings = {
            vnext = [{
              address = cfg.host;
              port = cfg.port;
              users = [{
                id = cfg.user;
                flow = "xtls-rprx-splice";
                encryption = "none";
              }];
            }];
          };
          streamSettings = {
            security = "xtls";
            sockopt = { mark = 2; };
          };
        }];
      };
      xray-config = writeText "xray-config.json"
        (builtins.toJSON (recursiveMerge [ basicConfig cfg.extraConfig ]));
    in {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "ipset.service" ];
      requires = [ "ipset.service" ];
      path = [ xray iproute2 iptables ];
      script = ''
        ulimit -n 65536
        ip rule add fwmark 1 table 100
        ip route add local 0.0.0.0/0 dev lo table 100

        iptables -w -t mangle -N XRAY
        iptables -w -t mangle -A XRAY -m set --match-set ignore dst -j RETURN
        iptables -w -t mangle -A XRAY -p tcp -j TPROXY --on-port 1024 --tproxy-mark 1
        iptables -w -t mangle -A XRAY -p udp -j TPROXY --on-port 1024 --tproxy-mark 1
        iptables -w -t mangle -A PREROUTING -j XRAY

        iptables -w -t mangle -N XRAY_SELF
        iptables -w -t mangle -A XRAY_SELF -m mark --mark 2 -j RETURN
        iptables -w -t mangle -A XRAY_SELF -m set --match-set ignore dst -j RETURN
        iptables -w -t mangle -A XRAY_SELF -p tcp -j MARK --set-mark 1
        iptables -w -t mangle -A XRAY_SELF -p udp -j MARK --set-mark 1
        iptables -w -t mangle -A OUTPUT -j XRAY_SELF

        exec xray -c ${xray-config}
      '';
      preStop = ''
        ip rule del fwmark 1 table 100
        ip route del local 0.0.0.0/0 dev lo table 100

        iptables -t mangle -D PREROUTING -j XRAY
        iptables -t mangle -F XRAY
        iptables -t mangle -X XRAY

        iptables -t mangle -D OUTPUT -j XRAY_SELF
        iptables -t mangle -F XRAY_SELF
        iptables -t mangle -X XRAY_SELF
      '';
    };
    systemd.services.overture = let
      overture = stdenv.mkDerivation {
        name = "overture";
        src = fetchzip {
          url = "https://github.com/shawn1m/overture/releases/download/"
            + "v1.8/overture-linux-amd64.zip";
          hash = "sha256-yoVvopu4lcw4jbOetQ+Ktir9tAtJ0nd9dEekSeQF1C8=";
          stripRoot = false;
        };
        installPhase = let
          overture-config = writeText "overture-config.yml" ''
            bindAddress: 127.0.0.1:53
            debugHTTPAddress: 127.0.0.1:5555
            dohEnabled: false
            primaryDNS:
              - name: PrimaryDNS
                address: ${head cfg.dns}
                protocol: udp
                socks5Address:
                timeout: 6
                ednsClientSubnet:
                  policy: disable
                  externalIP:
                  noCookie: true
            alternativeDNS:
              - name: AlternativeDNS
                address: ${last cfg.dns}
                protocol: tcp
                socks5Address:
                timeout: 6
                ednsClientSubnet:
                  policy: disable
                  externalIP:
                  noCookie: true
            onlyPrimaryDNS: false
            ipv6UseAlternativeDNS: false
            alternativeDNSConcurrent: false
            whenPrimaryDNSAnswerNoneUse: alternativeDNS
            ipNetworkFile:
              primary: ./ip_network_primary_sample
              alternative: ./ip_network_alternative_sample
            domainFile:
              primary: ./domain_primary_sample
              alternative: ./domain_alternative_sample
              matcher: full-map
            hostsFile:
              hostsFile: ./hosts_sample
              finder: full-map
            minimumTTL: 0
            domainTTLFile: ./domain_ttl_sample
            cacheSize: 4096
            cacheRedisUrl:
            cacheRedisConnectionPoolSize:
            rejectQType:
              - 255
          '';
        in ''
          mkdir -p $out/bin
          cp overture-linux-amd64 $out/bin/overture
          mkdir -p $out/etc
          cp config.yml *_sample $out/etc/
          ln -sf ${overture-config} $out/etc/config.yml
          ln -sf ${china-ip-list}/ignore.list $out/etc/ip_network_primary_sample
        '';
      };
    in {
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
      path = [ overture ];
      script = "exec overture";
      serviceConfig = { WorkingDirectory = "${overture}/etc"; };
    };
    networking.nameservers = [ "127.0.0.1" ];
    boot.kernel.sysctl."net.ipv6.conf.all.disable_ipv6" = 1;
  };
}
