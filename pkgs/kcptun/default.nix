{ stdenv, fetchurl }:

stdenv.mkDerivation rec {
  name = "kcptun-${version}";
  version = "20221015";
  src = fetchurl {
    url = "https://github.com/xtaci/kcptun/releases/download/"
      + "v${version}/kcptun-linux-amd64-${version}.tar.gz";
    sha256 = "sha256-JEvReuOK/PTQBDquaFU3YYBrzF/T20BieAxNN0yIHCg=";
  };
  unpackPhase = "tar zxf $src";
  installPhase = ''
    mkdir -p $out/bin
    cp client_linux_amd64 $out/bin/kcptun-client
    cp server_linux_amd64 $out/bin/kcptun-server
  '';
}
