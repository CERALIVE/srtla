"""Real SSH host-key rejection, with generated keys and no privileged service."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from capacity_remote import Generator
from capacity_ssh_test_support import ssh_peer


class SshHostKeyTests(unittest.TestCase):
    def test_unknown_and_mismatched_generator_host_keys_fail_closed(self) -> None:
        for key_state in ("unknown", "mismatched"):
            with self.subTest(key_state=key_state), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                with ssh_peer(root, key_state) as (config, known_hosts, unsafe_hosts):
                    pinned = known_hosts.read_bytes()
                    bench = root / "bench"
                    bench.mkdir()
                    with self.assertRaisesRegex(RuntimeError, "^generator_exited:255$"):
                        with Generator(config, bench):
                            self.fail("untrusted SSH host reached the generator worker")
                    self.assertEqual(known_hosts.read_bytes(), pinned)
                    self.assertEqual(unsafe_hosts.read_bytes(), b"")

    def test_caller_pinned_generator_host_key_allows_control(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            with ssh_peer(root, "pinned") as (config, known_hosts, unsafe_hosts):
                pinned = known_hosts.read_bytes()
                bench = root / "bench"
                bench.mkdir()
                with Generator(config, bench) as generator:
                    self.assertEqual(generator.provenance["sender_sha"], config["sender_sha"])
                self.assertEqual(known_hosts.read_bytes(), pinned)
                self.assertEqual(unsafe_hosts.read_bytes(), b"")


if __name__ == "__main__":
    unittest.main()
