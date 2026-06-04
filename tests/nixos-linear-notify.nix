{
  pkgs,
  module,
}:

{
  name = "linear-notify";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [ module ];

      system.stateVersion = "26.05";

      users.users.alice = {
        isNormalUser = true;
        linger = true;
        uid = 1000;
      };

      systemd.tmpfiles.rules = [
        "f /run/linear-token 0600 alice users - test-token"
      ];

      services.linear-notify = {
        enable = true;
        package = pkgs.writeShellApplication {
          name = "linear-notify";
          text = ''
            printf '%s\n' "$@" > /tmp/linear-notify-argv
            id -un > /tmp/linear-notify-user
            sleep infinity
          '';
        };
        user = "alice";
        tokenFile = "/run/linear-token";
        intervalSeconds = 5;
        enableActions = true;
        extraArgs = [
          "--state-file"
          "/tmp/linear-state.json"
          "--request-timeout"
          "1"
        ];
      };
    };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("user@1000.service")

    machine.succeed("systemctl --user -M alice@ start linear-notify.service")
    machine.wait_until_succeeds("systemctl --user -M alice@ is-active linear-notify.service")

    machine.wait_until_succeeds("test \"$(cat /tmp/linear-notify-user)\" = alice")
    machine.wait_until_succeeds("test -s /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '--token-file' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '/run/linear-token' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '--interval' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '5' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '--enable-actions' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '--state-file' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '/tmp/linear-state.json' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '--request-timeout' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '1' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '${pkgs.libnotify}/bin/notify-send' /tmp/linear-notify-argv")
    machine.succeed("grep -Fx -- '${pkgs.xdg-utils}/bin/xdg-open' /tmp/linear-notify-argv")
  '';
}
