#!/usr/bin/env python3
"""
pve-api-example.py
Minimal example of talking to the Proxmox VE REST API with an API token.

Setup (one-time, on a PVE node):
    pveum user add automation@pve --password ChangeMe!
    pveum aclmod / -user automation@pve -role PVEVMAdmin
    pveum user token add automation@pve scripts --privsep=0
    # -> copy the resulting token value to the env var below

Usage:
    export PVE_HOST=10.10.10.11
    export PVE_USER=automation@pve
    export PVE_TOKEN_ID=scripts
    export PVE_TOKEN_SECRET=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    python3 pve-api-example.py list
    python3 pve-api-example.py start 101
    python3 pve-api-example.py snapshot 101 pre-deploy
"""
from __future__ import annotations

import json
import os
import sys
import urllib3
from typing import Any

try:
    import requests
except ImportError:
    sys.exit("pip install requests")

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

PVE_HOST = os.environ.get("PVE_HOST", "10.10.10.11")
PVE_USER = os.environ.get("PVE_USER", "automation@pve")
TOKEN_ID = os.environ.get("PVE_TOKEN_ID", "scripts")
TOKEN_SECRET = os.environ.get("PVE_TOKEN_SECRET")
VERIFY_TLS = os.environ.get("PVE_VERIFY_TLS", "false").lower() == "true"

if not TOKEN_SECRET:
    sys.exit("Set PVE_TOKEN_SECRET in the environment.")

BASE = f"https://{PVE_HOST}:8006/api2/json"
HEADERS = {
    "Authorization": f"PVEAPIToken={PVE_USER}!{TOKEN_ID}={TOKEN_SECRET}",
}


def api(method: str, path: str, **params: Any) -> dict:
    url = f"{BASE}{path}"
    fn = getattr(requests, method.lower())
    kwargs: dict[str, Any] = {"headers": HEADERS, "verify": VERIFY_TLS, "timeout": 30}
    if method.upper() in ("POST", "PUT"):
        kwargs["data"] = params
    else:
        kwargs["params"] = params
    r = fn(url, **kwargs)
    r.raise_for_status()
    return r.json().get("data", {})


def node_name() -> str:
    nodes = api("GET", "/nodes")
    return nodes[0]["node"]


def cmd_list() -> None:
    node = node_name()
    print(f"# VMs on node {node}")
    for vm in sorted(api("GET", f"/nodes/{node}/qemu"), key=lambda v: v["vmid"]):
        print(f"  {vm['vmid']:>5}  {vm['status']:>9}  {vm.get('name','')}")
    print(f"# Containers on node {node}")
    for ct in sorted(api("GET", f"/nodes/{node}/lxc"), key=lambda v: v["vmid"]):
        print(f"  {ct['vmid']:>5}  {ct['status']:>9}  {ct.get('name','')}")


def cmd_start(vmid: str) -> None:
    node = node_name()
    print(api("POST", f"/nodes/{node}/qemu/{vmid}/status/start"))


def cmd_stop(vmid: str) -> None:
    node = node_name()
    print(api("POST", f"/nodes/{node}/qemu/{vmid}/status/shutdown"))


def cmd_snapshot(vmid: str, name: str) -> None:
    node = node_name()
    print(api("POST", f"/nodes/{node}/qemu/{vmid}/snapshot", snapname=name))


def cmd_status(vmid: str) -> None:
    node = node_name()
    print(json.dumps(api("GET", f"/nodes/{node}/qemu/{vmid}/status/current"), indent=2))


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd, *rest = sys.argv[1:]
    handlers = {
        "list":     lambda: cmd_list(),
        "start":    lambda: cmd_start(rest[0]),
        "stop":     lambda: cmd_stop(rest[0]),
        "status":   lambda: cmd_status(rest[0]),
        "snapshot": lambda: cmd_snapshot(rest[0], rest[1]),
    }
    if cmd not in handlers:
        sys.exit(f"Unknown command '{cmd}'. Use: {', '.join(handlers)}")
    handlers[cmd]()


if __name__ == "__main__":
    main()
