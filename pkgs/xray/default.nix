{ stdenv, fetchzip }:

stdenv.mkDerivation rec {
  name = "xray-${version}";
  version = "1.7.5";
  src = fetchzip {
    url = "https://github.com/XTLS/Xray-core/releases/download/"
      + "v${version}/Xray-linux-64.zip";
    hash = "sha256-ZCkHZcV9hwATXRVAHZ/hj8CotE/lDU9WQal0K5bLBvM=";
    stripRoot = false;
  };
  installPhase = ''
    mkdir -p $out/bin
    cp xray $out/bin/
  '';
}
