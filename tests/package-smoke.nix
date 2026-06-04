{
  runCommand,
  linear-notify,
}:

runCommand "linear-notify-package-smoke" { } ''
  test -x ${linear-notify}/bin/linear-notify
  ${linear-notify}/bin/linear-notify --help >/dev/null

  ! grep -R '@notifySend@' ${linear-notify}/bin/linear-notify
  ! grep -R '@xdgOpen@' ${linear-notify}/bin/linear-notify

  touch $out
''
