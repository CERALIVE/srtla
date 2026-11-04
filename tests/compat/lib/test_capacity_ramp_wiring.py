"""Exercise real capture assembly across local and remote generator boundaries."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from contextlib import contextmanager, redirect_stdout
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import capacity_live
import capacity_ramp_live as live
from benchmark_live import Processes, PrerequisiteError
from capacity_remote_test_support import config_for, exited

PROFILE = {"bitrate_mbps": 6, "links": 2}


@contextmanager
def capture_boundaries():
    """Use real process ownership/control and replace only receiver/OS sampling."""
    original_start = Processes.start
    original_exists = Path.exists
    clock = iter([0, 0, 10, 10, 20, 20, 20])
    metrics = {
        "srtla_groups": 1, "srtla_groups_established": 1, "srtla_connections": 2,
        "srtla_auth_failures_total": 0, "srtla_packets_received_total": 1000,
        "srtla_recv_batches_total": 100,
        **{f'srtla_groups_removed_total{{reason="{reason}"}}': 0
           for reason in ("evicted", "idle_timeout", "srt_error", "auth_failed")},
    }

    def start(owner, command, log, marker=None, **kwargs):
        if log.name == "receiver.log":
            command = [sys.executable, "-c",
                       "import signal;print('srtla_rec is now running',flush=True);signal.pause()"]
        return original_start(owner, command, log, marker, **kwargs)

    def exists(path):
        return path == Path("/sys/class/net/bench-uplink/device") or original_exists(path)

    with patch.object(Processes, "start", start), patch.object(Path, "exists", exists), \
            patch("capacity_live.time", SimpleNamespace(monotonic=lambda: next(clock))), \
            patch("capacity_live.threading", SimpleNamespace(Event=lambda: SimpleNamespace(wait=lambda _: None))), \
            patch("capacity_live.cpu_counters", side_effect=[
                [[0, 0, 0, 100, 0, 0, 0, 0]], [[0, 0, 0, 100, 0, 0, 0, 0]],
                [[10, 0, 0, 190, 0, 0, 0, 0]], [[20, 0, 0, 280, 0, 0, 0, 0]],
            ]), \
            patch("capacity_live.nic_counters", side_effect=[
                [0] * 4, [0] * 4, [10000000, 20000000, 1000, 2000],
                [20000000, 40000000, 2000, 4000],
            ]), \
            patch("capacity_live.metrics", return_value=metrics), redirect_stdout(StringIO()):
        yield


class RampWiringTests(unittest.TestCase):
    def test_remote_capture_uses_generator_link_plan_without_local_addresses(self) -> None:
        for addresses in (None, [], ["unused-local-address"]):
            with self.subTest(addresses=addresses), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                options = config_for(root, simulated=True)
                options.update(rule="v3", mode="ramp", step_s=20, max_bonds=5)
                options["calibration"] = {"host": "198.18.0.2", "port": 43000, "offered_mbps": [10]}
                if addresses is None:
                    del options["link_addresses"]
                else:
                    options["link_addresses"] = addresses
                options["srt_stats"] = {"argv": [
                    sys.executable, "-c",
                    "import json;print(json.dumps(dict(pkt_rcv_drop=2,pkt_rcv_loss=3,publishers=1,disconnects=0)))",
                ]}
                bench = root / "bench"
                bench.mkdir()

                def campaign(config, collect):
                    return {"softCapBonds": 0, "cell": collect(1, PROFILE, config["step_s"], "ramp")}

                with capture_boundaries(), \
                        patch.object(live, "calibrate", return_value=({"in": 10, "out": 10}, {"in": 100, "out": 100}, [])), \
                        patch.object(live, "campaign", side_effect=campaign):
                    result = live.capture(options, bench)

                measured = result["cell"]
                self.assertNotIn("failure", measured)
                self.assertEqual([s["elapsed_s"] for s in measured["samples"]], [0, 10, 20])
                self.assertEqual((measured["offered_goodput_mbps"], measured["delivered_goodput_mbps"]), (6, 6))
                remote = json.loads((bench / "ramp/capture/generator.json").read_text())
                self.assertEqual(Path(remote["directory"], "ips.txt").read_text().splitlines(), ["198.18.0.2"] * 2)
                self.assertFalse((bench / "ramp/capture/ips.txt").exists())
                self.assertFalse(list(Path(remote["directory"]).glob("delivered-*.ts")))
                exited(remote["pids"])

    def test_local_measure_writes_configured_links_and_rejects_too_few(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            options = config_for(root)
            del options["generator"]
            options.update(duration_s=20, link_addresses=["127.0.0.1", "127.0.0.2"])
            with capture_boundaries():
                measured = live.measure(options, root / "local", 1, 6, 2)
            self.assertEqual((root / "local/ips.txt").read_text().splitlines(), ["127.0.0.1", "127.0.0.2"])
            self.assertEqual(measured["packets_received"], [1000, 1000, 1000])
            options["link_addresses"] = ["127.0.0.1"]
            with self.assertRaisesRegex(PrerequisiteError, "^missing_uplink_addresses:need_2$"):
                capacity_live.measure(options, root / "missing", 1, 6, 2)


if __name__ == "__main__":
    unittest.main()
