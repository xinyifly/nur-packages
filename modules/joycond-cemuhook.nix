{ config, lib, pkgs, ... }:

with pkgs;
let
  joycond-cemuhook = python3.pkgs.buildPythonPackage {
    name = "joycond-cemuhook";
    format = "pyproject";
    src = fetchFromGitHub {
      owner = "joaorb64";
      repo = "joycond-cemuhook";
      rev = "484433254960b0c5374413808727fa0ce7c40d8a";
      hash = "sha256-0fXkz/Zc+KwNv/NaxEiCozPu2nDM4DgJQty84K8orYo=";
    };
    postPatch = ''
      sed -i '/"asyncio"/d' pyproject.toml
    '';
    propagatedBuildInputs = with python3.pkgs; [
      dbus-python
      evdev
      pyudev
      setuptools
      termcolor
    ];
  };
in {
  config = lib.mkIf config.services.joycond.enable {
    systemd.services.joycond-cemuhook = {
      wantedBy = [ "multi-user.target" ];
      after = [ "joycond.service" ];
      bindsTo = [ "joycond.service" ];
      path = [ joycond-cemuhook kmod ];
      script = "joycond-cemuhook";
      preStart = "modprobe hid_nintendo";
    };
  };
}
