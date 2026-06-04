{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.linear-notify;
  absolutePath = lib.types.strMatching "^/.*";

  defaultPackage = pkgs.callPackage ../../packages/linear-notify/package.nix { };
  userGate = pkgs.writeShellScript "linear-notify-only-user" ''
    [ "$1" = ${lib.escapeShellArg cfg.user} ]
  '';

  command = "${cfg.package}/bin/linear-notify";
  commandArgs = [
    command
    "--token-file"
    cfg.tokenFile
    "--interval"
    (toString cfg.intervalSeconds)
    "--notify-send"
    "${pkgs.libnotify}/bin/notify-send"
    "--xdg-open"
    "${pkgs.xdg-utils}/bin/xdg-open"
  ]
  ++ lib.optional cfg.enableActions "--enable-actions"
  ++ cfg.extraArgs;
in
{
  options.services.linear-notify = {
    enable = lib.mkEnableOption "Linear desktop notification daemon";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.callPackage ../../packages/linear-notify/package.nix { }";
      description = "linear-notify package to run.";
    };

    user = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "alice";
      description = "User whose graphical session runs linear-notify.";
    };

    tokenFile = lib.mkOption {
      type = absolutePath;
      default = "/run/secrets/linear-api-key";
      example = "/run/secrets/linear-api-key";
      description = "Absolute runtime path to file containing Linear API token. Do not point this at a Nix store path.";
    };

    intervalSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 45;
      description = "Polling interval in seconds.";
    };

    enableActions = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable notification action button for opening Linear notification URLs.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--page-size"
        "100"
      ];
      description = "Additional arguments passed to linear-notify. Later arguments override module defaults when argparse accepts repeated flags.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.user != null && cfg.user != "";
        message = "services.linear-notify.user must be set to the graphical session user";
      }
      {
        assertion = cfg.intervalSeconds >= 5;
        message = "services.linear-notify.intervalSeconds must be >= 5";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    systemd.user.services.linear-notify = {
      description = "Linear desktop notification daemon";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      wants = [ "dbus.socket" ];
      after = [
        "graphical-session.target"
        "dbus.socket"
      ];
      serviceConfig = {
        Type = "simple";
        ExecCondition = "${userGate} %u";
        ExecStart = lib.escapeShellArgs commandArgs;
        Restart = "always";
        RestartSec = "30s";
        Slice = "session.slice";
      };
    };
  };
}
