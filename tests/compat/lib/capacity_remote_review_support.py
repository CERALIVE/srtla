"""Focused capture fixtures for remote wiring, hashing and calibration ownership."""

from __future__ import annotations

import copy
import os
import selectors
from pathlib import Path
from unittest.mock import patch

import capacity_live
from capacity_remote_test_support import peer


def matrix_capture(root: Path, config: dict) -> tuple[dict, dict]:
    """Keep the real capture/evaluator and observe the peer around calibration."""
    from test_benchmark_harnesses import capacity_fixture

    fixture = capacity_fixture()
    observed = {"peer_alive_at_calibration": False, "peer_exited_before_media": False}
    pidfd = None
    with peer(root, config) as (generator, bench), selectors.DefaultSelector() as selector:
        def calibrate(config, directory):
            nonlocal pidfd
            records = [record for record in generator.exchanges if record["operation"] == "iperf"]
            if records:
                pidfd = os.pidfd_open(records[-1]["response"]["pid"])
                selector.register(pidfd, selectors.EVENT_READ)
                observed["peer_alive_at_calibration"] = not bool(selector.select(0))
            return fixture["sustainable_nic_mbps"], fixture["sustainable_pps"], []

        def collect(config, directory, bonds, bitrate, links, *, generator):
            directory.mkdir()
            if pidfd is not None:
                observed["peer_exited_before_media"] = bool(selector.select(0))
            cell = copy.deepcopy(next(
                cell for cell in fixture["cells"]
                if cell["bitrate_mbps"] == bitrate and cell["links"] == links
            ))
            cell.update(receiver_cpu_pct=10, offered_goodput_mbps=bonds * bitrate)
            return cell

        try:
            with patch("capacity_live.calibrate", side_effect=calibrate), \
                    patch("capacity_live.measure", side_effect=collect), \
                    patch.object(generator, "retire"), \
                    patch("capacity_live.preview_trials", return_value=fixture["preview_trials"]):
                result = capacity_live.capture_matrix(config, bench, generator=generator)
        finally:
            if pidfd is not None:
                selector.unregister(pidfd)
                os.close(pidfd)
    return result, observed
