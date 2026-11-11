{
  pkgs ? import <nixpkgs> { },
}:

pkgs.mkShell {
  # Used by zig/download.sh and zig/zls/download.sh.
  buildInputs = with pkgs; [
    bash
    coreutils
    curl
    gnugrep
    gnutar
    xz
  ];

  shellHook = ''
    export PATH="${toString ./zig}:$PATH"
  '';
}
