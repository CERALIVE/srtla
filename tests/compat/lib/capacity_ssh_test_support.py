"""Disposable, unprivileged inetd-mode OpenSSH server for host-key tests."""

from __future__ import annotations

import errno
import getpass
import os
import signal
import socket
import subprocess
import sys
import threading
from contextlib import contextmanager
from pathlib import Path

from benchmark_live import require_tool
from capacity_remote_test_support import config_for


@contextmanager
def ssh_peer(root: Path, key_state: str):
    host_key, client_key = root / "host-key", root / "client-key"
    for key in (host_key, client_key):
        subprocess.run([
            require_tool("ssh-keygen"), "-q", "-t", "ed25519", "-N", "", "-f", str(key),
        ], check=True, capture_output=True, timeout=10)
    with socket.socket() as listener:
        for service_port in range(43000, 44000):
            try:
                listener.bind(("127.0.0.1", service_port))
                break
            except OSError as error:
                if error.errno != errno.EADDRINUSE:
                    raise
        else:
            raise RuntimeError("no_available_h1_ssh_test_port")
        listener.listen(1)
        listener.settimeout(10)
        known_hosts, unsafe_hosts = root / "known_hosts", root / "unsafe_hosts"
        known_hosts.write_text("")
        unsafe_hosts.write_text("")
        if key_state != "unknown":
            public = (host_key if key_state == "pinned" else client_key).with_suffix(".pub").read_text()
            known_hosts.write_text(f"[127.0.0.1]:{service_port} {public}")
        daemon_config = root / "sshd_config"
        daemon_config.write_text(
            f"HostKey {host_key}\nAuthorizedKeysFile {client_key}.pub\n"
            "StrictModes no\nUsePAM no\nPasswordAuthentication no\n"
            "KbdInteractiveAuthentication no\nPubkeyAuthentication yes\n"
            "LogLevel DEBUG\n"
        )
        children, errors = [], []

        def serve() -> None:
            try:
                connection, _ = listener.accept()
                with connection, (root / "sshd.log").open("wb") as log:
                    child = subprocess.Popen(
                        [require_tool("sshd"), "-i", "-e", "-f", str(daemon_config)],
                        stdin=connection, stdout=connection, stderr=log, start_new_session=True,
                    )
                    children.append(child)
                    try:
                        child.wait(timeout=20)
                    finally:
                        if child.poll() is None:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait(timeout=5)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                errors.append(error)

        server = threading.Thread(target=serve, daemon=True)
        server.start()
        config = config_for(root)
        config["generator"].update({
            "known_hosts": str(known_hosts),
            "argv": [
                require_tool("ssh"), "-F", "/dev/null", "-T", "-p", str(service_port),
                "-l", getpass.getuser(), "-i", str(client_key),
                "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                "-o", "ConnectTimeout=5",
                # Mandatory pinning must override these unsafe caller options.
                "-o", "StrictHostKeyChecking=no", "-o", f"UserKnownHostsFile={unsafe_hosts}",
                "127.0.0.1", sys.executable,
                str(Path(__file__).with_name("capacity_generator.py")),
            ],
        })
        if key_state == "mismatched":
            alias = root / "ssh-alias"
            alias.symlink_to(require_tool("ssh"))
            config["generator"]["argv"][0] = str(alias)
        try:
            yield config, known_hosts, unsafe_hosts
        finally:
            for child in children:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
            server.join(timeout=15)
            if server.is_alive():
                raise RuntimeError("ssh_test_server_survived_teardown")
            if errors:
                raise RuntimeError("ssh_test_server_failed") from errors[0]
