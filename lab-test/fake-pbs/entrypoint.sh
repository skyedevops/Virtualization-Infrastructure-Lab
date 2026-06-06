#!/usr/bin/env bash
# entrypoint.sh - bring up sshd + init state.json for the fake-pbs
# container.  The /etc/pbs-test.conf placeholder is left in place;
# real fault injection is done by bind-mounting a custom file at
# container start.

set -euo pipefail

mkdir -p /var/log/pbs /var/lib/pbs
if [[ ! -s /var/lib/pbs/state.json ]] \
   || ! jq -e . /var/lib/pbs/state.json >/dev/null 2>&1; then
  printf '{"datastores":{},"snapshots":{},"prune_jobs":{}}\n' \
    > /var/lib/pbs/state.json
fi

# Run sshd in the foreground (container PID 1).
exec /usr/sbin/sshd -D -e
