# lab-test/fake-pve/Dockerfile
#
# A fake Proxmox host for integration-testing labctl.py end-to-end.
# Runs sshd with a baked-in public key so labctl's SshTransport can
# drive `qm create / qm set / qm start` against it without needing a
# real Proxmox cluster.
#
# Build:
#   docker build -t lab-test/fake-pve:latest lab-test/fake-pve
# Run:
#   docker run -d --name fake-pve -p 2226:22 lab-test/fake-pve:latest
# Smoke:
#   ssh -i lab-test/fixtures/id_ed25519 -p 2226 \
#       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
#       root@127.0.0.1 'qm list'

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        openssh-server openssh-client jq ca-certificates && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -s /bin/bash labadmin && \
    mkdir -p /run/sshd /var/log/lab /var/lib/lab /root/.ssh && \
    chmod 700 /root/.ssh && \
    passwd -d root && passwd -d labadmin

# Minimal sshd config:
#   - root login with key only
#   - publickey auth on
#   - PAM off (avoids /run/utmp session-open issues in containers)
#   - permit empty passwords (no password auth at all)
RUN printf '%s\n' \
        'Port 22' \
        'PermitRootLogin prohibit-password' \
        'PubkeyAuthentication yes' \
        'AuthorizedKeysFile /root/.ssh/authorized_keys' \
        'PasswordAuthentication no' \
        'PermitEmptyPasswords yes' \
        'UsePAM no' \
        'ChallengeResponseAuthentication no' \
        'KbdInteractiveAuthentication no' \
        'X11Forwarding no' \
        'PrintMotd no' \
        'AcceptEnv LANG LC_*' \
        'Subsystem sftp /usr/lib/openssh/sftp-server' \
        > /etc/ssh/sshd_config.test && \
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak && \
    cp /etc/ssh/sshd_config.test /etc/ssh/sshd_config && \
    rm /etc/ssh/sshd_config.test

COPY qm /usr/local/bin/qm
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY authorized_keys /root/.ssh/authorized_keys

# Lab-test config file.  The qm shim sources this on every invocation so
# tests can inject fault-injection knobs without going through ssh's
# env sanitization.  Override at run time with `-v $PWD/lab-test.conf:/etc/lab-test.conf:ro`.
RUN printf '%s\n' \
        '# Lab-test fake-pve runtime config' \
        '# Format: KEY=value, one per line, comments with #' \
        '# Available knobs:' \
        '#   QM_FAIL_VMIDS - comma-separated VMIDs whose `qm create` will exit 1' \
        > /etc/lab-test.conf && \
    chmod 644 /etc/lab-test.conf

RUN chmod +x /usr/local/bin/qm /usr/local/bin/entrypoint.sh && \
    chown -R root:root /root/.ssh && \
    chmod 600 /root/.ssh/authorized_keys && \
    echo 'fake-pve:0.1.0' > /etc/lab-release

EXPOSE 22

# A healthcheck proves sshd is up (the test uses it to wait for ready)
HEALTHCHECK --interval=2s --timeout=2s --start-period=5s --retries=10 \
    CMD nc -z 127.0.0.1 22 || exit 1

CMD ["/usr/local/bin/entrypoint.sh"]
