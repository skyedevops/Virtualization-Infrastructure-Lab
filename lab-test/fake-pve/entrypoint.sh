#!/bin/bash
# entrypoint.sh - bring sshd up and stay foregrounded.
set -euo pipefail
mkdir -p /run/sshd /var/log/lab /var/lib/lab
: > /var/log/lab/qm.log
printf '{"vms":[]}\n' > /var/lib/lab/state.json
exec /usr/sbin/sshd -D -e
