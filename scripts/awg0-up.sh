#!/usr/bin/env bash
for _ in 1 2 3 4 5 6; do
  /usr/bin/awg-quick down wg0 >/dev/null 2>&1 || true
  /usr/bin/awg-quick up wg0 && exit 0
  sleep 5
done
echo "awg0: wg0 не поднялся за 6 попыток" >&2
exit 1
