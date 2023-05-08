{ config, pkgs, lib, ... }:

with builtins;
let
  cfg = config.services.xray-redir;
  outbounds = let
    parse = host:
      with lib;
      let arr = splitString ":" host;
      in {
        address = head arr;
        port = toInt (head (tail arr));
      };
  in map (server:
    if server.type == "vision" then {
      tag = server.tag;
      protocol = "vless";
      settings = {
        vnext = let host = parse server.host;
        in [{
          address = host.address;
          port = host.port;
          users = [{
            id = server.user;
            flow = "xtls-rprx-vision";
            encryption = "none";
          }];
        }];
      };
      streamSettings = { security = "tls"; };
    } else if server.type == "ssrdog" then {
      tag = server.tag;
      protocol = "vmess";
      settings = {
        vnext = let host = parse server.host;
        in [{
          address = host.address;
          port = host.port;
          users = [{ id = server.user; }];
        }];
      };
      streamSettings = {
        network = "ws";
        wsSettings = {
          connectionReuse = true;
          path = "";
          headers = { Host = ""; };
        };
      };
      mux = { enabled = true; };
    } else
      { }) cfg.servers;
  openai = lib.findFirst (o: o.tag == "openai") null outbounds;
  defaults = {
    inbounds = [{
      port = 12345;
      protocol = "dokodemo-door";
      settings = {
        network = "tcp,udp";
        followRedirect = true;
      };
      streamSettings = { sockopt = { tproxy = "tproxy"; }; };
      sniffing = {
        enabled = true;
        destOverride = [ "http" "tls" "quic" ];
      };
    }];
    outbounds = outbounds ++ [
      {
        tag = "direct";
        protocol = "freedom";
      }
      {
        tag = "dns";
        protocol = "dns";
      }
    ];
    dns = {
      servers = [
        {
          address = cfg.dns;
          expectIPs =
            [ "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "100.64.0.0/10" ]
            ++ [ "geoip:cn" ];
        }
        "8.8.8.8"
        "1.1.1.1"
      ] ++ (if openai != null then [{
        address = "8.8.4.4";
        domains = [ "domain:openai.com" ];
      }] else
        [ ]);
    };
    routing = {
      domainStrategy = "IPOnDemand";
      rules = [
        {
          type = "field";
          ip = [ "geoip:private" "geoip:cn" ];
          network = "udp";
          port = "53";
          outboundTag = "dns";
        }
        {
          type = "field";
          ip = [ "geoip:private" "geoip:cn" ];
          outboundTag = "direct";
        }
      ] ++ (if openai != null then [
        {
          type = "field";
          ip = [ "8.8.4.4" ];
          outboundTag = "openai";
        }
        {
          type = "field";
          domain = [ "domain:openai.com" ];
          outboundTag = "openai";
        }
      ] else
        [ ]);
    };
  };
in {
  options = {
    services.xray-redir = with lib;
      with types; {
        enable = mkOption {
          type = bool;
          default = false;
        };
        servers = mkOption { type = listOf attrs; };
        dns = mkOption {
          type = uniq string;
          default = "localhost";
        };
        settings = mkOption {
          type = attrs;
          default = { };
        };
      };
  };
  config = lib.mkIf cfg.enable {
    users.groups.xray.gid = 23333;
    services.xray = let
    in {
      enable = true;
      package = with pkgs;
        let
          version = "1.8.1";
          src = fetchFromGitHub {
            owner = "XTLS";
            repo = "Xray-core";
            rev = "bfd5da2f0020e9856602c1d624cdf2e7914e545e";
            sha256 = "sha256-/e0sJnbzbIERTc3/QjzMVqULwCERAo8eF5coIxC6hDA=";
          };
          assetsDrv = symlinkJoin {
            name = "v2ray-assets";
            paths = [ v2ray-geoip v2ray-domain-list-community ];
          };
        in xray.override {
          buildGoModule = args:
            buildGoModule (args // {
              inherit src version;
              vendorSha256 =
                "sha256-IMkcV1R9PNtA46H7tof+cXzlEUZWTXcp74ah2CI7YY0=";
              installPhase = ''
                runHook preInstall
                install -Dm555 "$GOPATH"/bin/main $out/bin/xray
                wrapProgram $out/bin/xray \
                  --suffix XRAY_LOCATION_ASSET : $assetsDrv/share/v2ray
                runHook postInstall
              '';
            });
        };
      settings = let
        recursiveMerge = sets:
          with lib;
          zipAttrsWith (name: values:
            if all isList values then
              concatLists values
            else if all isAttrs values then
              recursiveMerge values
            else
              head values) sets;
      in recursiveMerge [ cfg.settings defaults ];
    };
    systemd.services.xray = {
      path = with pkgs; [ iproute2 iptables iputils ];
      serviceConfig = {
        User = "root";
        Group = "xray";
        DynamicUser = lib.mkForce false;
        LimitNOFILE = 65536;
      };
      preStart = ''
        until ping -c1 -W1 223.5.5.5 > /dev/null; do sleep 1; done

        ip rule add fwmark 1 table 100
        ip route add local 0.0.0.0/0 dev lo table 100

        iptables -w -t mangle -N XRAY
        iptables -w -t mangle -A XRAY -m addrtype --dst-type LOCAL -j RETURN
        iptables -w -t mangle -A XRAY -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1
        iptables -w -t mangle -A XRAY -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
        iptables -w -t mangle -A PREROUTING -j XRAY

        iptables -w -t mangle -N XRAY_MASK
        iptables -w -t mangle -A XRAY_MASK -m owner --gid-owner 23333 -j RETURN
        iptables -w -t mangle -A XRAY_MASK -m addrtype --dst-type LOCAL -j RETURN
        iptables -w -t mangle -A XRAY_MASK -p tcp -j MARK --set-mark 1
        iptables -w -t mangle -A XRAY_MASK -p udp -j MARK --set-mark 1
        iptables -w -t mangle -A OUTPUT -j XRAY_MASK
      '';
      preStop = ''
        ip rule del fwmark 1 table 100
        ip route del local 0.0.0.0/0 dev lo table 100

        iptables -w -t mangle -D PREROUTING -j XRAY
        iptables -w -t mangle -F XRAY
        iptables -w -t mangle -X XRAY

        iptables -w -t mangle -D OUTPUT -j XRAY_MASK
        iptables -w -t mangle -F XRAY_MASK
        iptables -w -t mangle -X XRAY_MASK
      '';
    };
  };
}
