{
  lib,
  stdenvNoCC,
  python3,
  libnotify,
  xdg-utils,
}:

let
  pname = "linear-notify";
  version = "0.1.0";
in
stdenvNoCC.mkDerivation {
  inherit pname version;

  src = ./.;

  nativeBuildInputs = [ python3 ];

  installPhase = ''
    runHook preInstall

    install -Dm755 linear-notify.py $out/bin/linear-notify
    substituteInPlace $out/bin/linear-notify \
      --replace-fail '@notifySend@' '${libnotify}/bin/notify-send' \
      --replace-fail '@xdgOpen@' '${xdg-utils}/bin/xdg-open'
    patchShebangs $out/bin/linear-notify

    runHook postInstall
  '';

  meta = {
    description = "Linear desktop notification daemon";
    license = lib.licenses.mit;
    mainProgram = pname;
    platforms = lib.platforms.linux;
  };
}
