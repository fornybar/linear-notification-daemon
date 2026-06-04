{
  lib,
  runCommand,
  nixosSystem,
  module,
  pkgs,
  system,
}:

let
  fakePackage = pkgs.writeShellApplication {
    name = "linear-notify";
    text = ''
      exit 0
    '';
  };

  enabledConfig = {
    system.stateVersion = "26.05";

    services.linear-notify = {
      enable = true;
      package = fakePackage;
      user = "alice";
      tokenFile = "/run/linear-token";
      intervalSeconds = 5;
      enableActions = true;
      extraArgs = [
        "--state-file"
        "/tmp/linear-state.json"
      ];
    };
  };

  moduleConfig =
    config:
    (nixosSystem {
      inherit system;
      modules = [
        module
        config
      ];
    }).config;

  moduleRejects =
    config:
    !(builtins.tryEval (builtins.deepSeq (moduleConfig config).system.build.toplevel true)).success;

  config = moduleConfig enabledConfig;
  noActionsConfig = moduleConfig {
    system.stateVersion = "26.05";

    services.linear-notify = {
      enable = true;
      package = fakePackage;
      user = "alice";
      tokenFile = "/run/linear-token";
      intervalSeconds = 5;
      enableActions = false;
    };
  };

  command = "${fakePackage}/bin/linear-notify";
  expectedExecStart = lib.escapeShellArgs [
    command
    "--token-file"
    "/run/linear-token"
    "--interval"
    "5"
    "--notify-send"
    "${pkgs.libnotify}/bin/notify-send"
    "--xdg-open"
    "${pkgs.xdg-utils}/bin/xdg-open"
    "--enable-actions"
    "--state-file"
    "/tmp/linear-state.json"
  ];
  expectedNoActionsExecStart = lib.escapeShellArgs [
    command
    "--token-file"
    "/run/linear-token"
    "--interval"
    "5"
    "--notify-send"
    "${pkgs.libnotify}/bin/notify-send"
    "--xdg-open"
    "${pkgs.xdg-utils}/bin/xdg-open"
  ];

  invalidConfigsRejected =
    assert moduleRejects {
      system.stateVersion = "26.05";
      services.linear-notify = {
        enable = true;
        package = fakePackage;
      };
    };
    assert moduleRejects {
      system.stateVersion = "26.05";
      services.linear-notify = {
        enable = true;
        package = fakePackage;
        user = "";
      };
    };
    assert moduleRejects {
      system.stateVersion = "26.05";
      services.linear-notify = {
        enable = true;
        package = fakePackage;
        user = "alice";
        intervalSeconds = 4;
      };
    };
    assert moduleRejects {
      system.stateVersion = "26.05";
      services.linear-notify = {
        enable = true;
        package = fakePackage;
        user = "alice";
        tokenFile = "secret";
      };
    };
    true;
in
runCommand "linear-notify-module-eval"
  {
    execStart = config.systemd.user.services.linear-notify.serviceConfig.ExecStart;
    inherit expectedExecStart;
    execCondition = config.systemd.user.services.linear-notify.serviceConfig.ExecCondition;
    noActionsExecStart = noActionsConfig.systemd.user.services.linear-notify.serviceConfig.ExecStart;
    inherit expectedNoActionsExecStart;
    packageInstalled = builtins.elem fakePackage config.environment.systemPackages;
    inherit invalidConfigsRejected;
  }
  ''
    test -n "$execCondition"
    test "$packageInstalled" = 1
    test "$invalidConfigsRejected" = 1

    if [ "$execStart" != "$expectedExecStart" ]; then
      echo "unexpected ExecStart" >&2
      echo "expected: $expectedExecStart" >&2
      echo "actual:   $execStart" >&2
      exit 1
    fi

    if [ "$noActionsExecStart" != "$expectedNoActionsExecStart" ]; then
      echo "unexpected ExecStart without actions" >&2
      echo "expected: $expectedNoActionsExecStart" >&2
      echo "actual:   $noActionsExecStart" >&2
      exit 1
    fi

    touch $out
  ''
