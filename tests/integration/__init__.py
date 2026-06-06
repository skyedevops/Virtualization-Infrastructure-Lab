"""
tests/integration - end-to-end integration tests for labctl.py.

These tests boot a fake Proxmox container (lab-test/fake-pve) and drive
the real labctl.py SshTransport against it.  They are intentionally
network-touching and require Docker on the host.
"""
