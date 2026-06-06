# =============================================================================
# fake-pbs/Dockerfile - a tiny container that pretends to be a Proxmox
# Backup Server.  The integration test (tests/integration/test_pbs_backup.py)
# runs `labctl pbs-init` / `pbs-status` / `pbs-restore-test` over SSH against
# this container to verify the PBS plumbing end-to-end without needing
# real Proxmox infrastructure.
#
# Image contents:
#   - openssh-server (only sshd + a 'root' account + the test authorized_keys)
#   - the proxmox-backup-manager shim from this directory
#   - /etc/pbs-test.conf placeholder for fault injection
# =============================================================================

FROM ubuntu:22.04

ARG AUTHORIZED_KEY
LABEL org.opencontainers.image.title="fake-pbs" \
      org.opencontainers.image.description="Fake PBS for the labctl integration test" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Install sshd + jq (used by the shim).  No need for the real PBS.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        software-properties-common \
    && add-apt-repository -y universe \
    && apt-get install -y --no-install-recommends \
        openssh-server jq ca-certificates python3 python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# Bake the test public key.
COPY authorized_keys /root/.ssh/authorized_keys

# sshd: key-only auth, no DNS, no PAM prompts.
RUN sed -i /etc/ssh/sshd_config \
        -e 's/^#\?UsePAM.*/UsePAM no/' \
        -e 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' \
        -e 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        -e 's/^#\?PermitEmptyPasswords.*/PermitEmptyPasswords yes/' \
    && mkdir -p /run/sshd

# PBS shim.  In a real PBS this would be /usr/sbin/proxmox-backup-manager;
# in the fake we put it in /usr/local/bin which is on $PATH.
COPY proxmox-backup-manager /usr/local/bin/proxmox-backup-manager

# Also copy the fake `qm` and `ha-manager` shims so the bash runbooks
# (pbs-restore-test.sh in particular) can be exercised against this
# container in the integration test.  In a real deployment, the
# runbook runs on the PVE node where the real qm lives, but for
# testing the PBS round-trip we want everything in one container.
COPY qm /usr/local/bin/qm
COPY ha-manager /usr/local/bin/ha-manager

# python3 + pyyaml are required by pbs-restore-test.sh (parses lab.yaml
# and snapshot list output).  Install via apt.
RUN apt-get install -y --no-install-recommends python3 python3-yaml \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# PBS-test config file.  The shim sources this on every call so
# tests can inject fault-injection knobs without going through ssh's
# env sanitization.  Override at run time with
# `-v $PWD/pbs-test.conf:/etc/pbs-test.conf:ro`.
RUN printf '%s\n' \
        '# fake-pbs runtime config' \
        '# Format: KEY=value, one per line, comments with #' \
        '# Available knobs:' \
        '#   PBS_FAIL_VMIDS - comma-separated VMIDs whose `pbs backup` exits 1' \
        > /etc/pbs-test.conf && \
    chmod 644 /etc/pbs-test.conf

RUN chmod +x /usr/local/bin/proxmox-backup-manager /usr/local/bin/entrypoint.sh && \
    chown -R root:root /root/.ssh && \
    chmod 600 /root/.ssh/authorized_keys && \
    echo 'fake-pbs:0.1.0' > /etc/pbs-release

EXPOSE 22

HEALTHCHECK --interval=2s --timeout=2s --start-period=5s --retries=10 \
    CMD nc -z 127.0.0.1 22 || exit 1

CMD ["/usr/local/bin/entrypoint.sh"]
