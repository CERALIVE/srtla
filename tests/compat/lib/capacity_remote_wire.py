#!/usr/bin/env python3
"""Explicit, unprivileged two-netns H1 smoke test; never provider qualification."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

from benchmark_live import Processes, require_tool
from capacity_live import measure
from capacity_remote import Generator


def run() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sender", required=True)
    parser.add_argument("--sender-sha", required=True)
    parser.add_argument("--receiver", required=True)
    parser.add_argument("--sls", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir()
    subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
    holder_code = "import os,signal; os.unshare(os.CLONE_NEWNET); print('NETNS_READY',flush=True); signal.pause()"
    records = []
    with Processes() as owners:
        holder = owners.start([sys.executable, "-c", holder_code], root / "netns.log", "NETNS_READY")

        def ip(*command: str, remote: bool = False) -> None:
            prefix = ["nsenter", "--target", str(holder.pid), "--net"] if remote else []
            subprocess.run([*prefix, "ip", *command], check=True, capture_output=True, timeout=10)

        ip("link", "add", "bench0", "type", "veth", "peer", "name", "gen0")
        ip("link", "set", "gen0", "netns", str(holder.pid))
        ip("addr", "add", "198.18.0.1/30", "dev", "bench0")
        ip("link", "set", "bench0", "up")
        ip("link", "set", "lo", "up", remote=True)
        ip("addr", "add", "198.18.0.2/30", "dev", "gen0", remote=True)
        ip("link", "set", "gen0", "up", remote=True)
        generator_root = root / "generator"
        generator_root.mkdir()
        sls_config = root / "sls.conf"
        sls_config.write_text(f"""srt {{
    worker_threads 1;
    worker_connections 100;
    http_port 43105;
    http_bind_addr 127.0.0.1;
    log_file /dev/null;
    log_level info;
    pidfile {root / 'sls.pid'};
    server {{
        listen_player 43104;
        listen_publisher_srtla 43102;
        latency_min 200;
        latency_max 5000;
        domain_player play;
        domain_publisher publish;
        backlog 1000;
        idle_streams_timeout 30;
        app {{
            app_player live;
            app_publisher live;
            allow publish all;
            allow play all;
        }}
    }}
}}
""")
        config = {
            "schema_version": 1, "provider_class": "local:two-netns-smoke",
            "interface": "bench0", "sender_ref": "main", "sender_sha": args.sender_sha,
            "receiver": str(Path(args.receiver).resolve()), "receiver_core": min(os.sched_getaffinity(0)),
            "duration_s": 4, "samples": 3, "link_addresses": ["198.18.0.2"],
            "port_base": 43100, "bonds": [1], "preview": {},
            "calibration": {"host": "198.18.0.2", "port": 43000},
            "generator": {
                "argv": ["nsenter", "--target", str(holder.pid), "--net", sys.executable,
                         str(Path(__file__).with_name("capacity_generator.py"))],
                "directory": str(generator_root), "source_address": "198.18.0.2",
                "receiver_host": "198.18.0.1",
            },
            "sls": {"argv": [str(Path(args.sls).resolve()), "-c", str(sls_config)], "ready": "libsrt_listen, ok"},
            "sender": {"argv": [str(Path(args.sender).resolve()), "{local_port}", "{receiver_host}",
                                "{receiver_port}", "{ips_file}"]},
            "load": {"argv": [
                require_tool("ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                "-re", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=25",
                "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
                "-g", "25",
                "-b:v", "{bitrate_mbps}M", "-minrate", "{bitrate_mbps}M",
                "-maxrate", "{bitrate_mbps}M", "-bufsize", "{bitrate_mbps}M",
                "-x264-params", "nal-hrd=cbr:force-cfr=1", "-f", "mpegts",
                "-progress", "pipe:1", "-flush_packets", "1",
                "srt://127.0.0.1:{local_port}?mode=caller&streamid=publish/live/bond-{bond}&pkt_size=1316",
            ], "ready": "total_size="},
            "sink": {"argv": [
                require_tool("ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
                "-probesize", "32", "-analyzeduration", "0",
                "-i", "srt://{receiver_host}:43104?mode=caller&streamid=play/live/bond-{bond}",
                "-map", "0", "-c", "copy", "-f", "mpegts", "-flush_packets", "1", "{media_file}",
            ]},
        }
        (root / "config.json").write_text(json.dumps(config, indent=2) + "\n")
        with Generator(config, root) as generator:
            # Configure a real peer in G, then stop it before any media starts.
            calibration_peer = generator.request("iperf")
            generator.request("stop")
            (root / "calibration-peer.json").write_text(json.dumps(calibration_peer) + "\n")
            request = generator.request
            wire = []

            def record(operation, payload=None):
                response = request(operation, payload)
                if operation == "alive":
                    content = subprocess.run(
                        ["nsenter", "--target", str(holder.pid), "--net", "ss", "-unap"],
                        check=True, capture_output=True, text=True, timeout=5,
                    ).stdout
                    wire.append(content)
                return response

            generator.request = record
            for links in (1, 4, 16):
                cell_dir = root / f"1-6-{links}"
                cell = measure(config, cell_dir, 1, 6, links, generator=generator)
                samples = json.loads((cell_dir / "samples.json").read_text())
                assert all(sample["metrics"]["srtla_groups"] == 1 for sample in samples)
                assert all(sample["metrics"]["srtla_connections"] == links for sample in samples)
                assert samples[-1]["nic"][0] > samples[0]["nic"][0]
                assert samples[-1]["nic"][1] > samples[0]["nic"][1]
                assert cell["delivered_goodput_mbps"] > 0
                endpoints = {
                    line.split()[3] for line in wire[-1].splitlines()
                    if "srtla_send" in line and "198.18.0.2:" in line
                }
                assert len(endpoints) == links, (links, endpoints, wire[-1])
                remote = json.loads((cell_dir / "generator.json").read_text())
                assert not list(cell_dir.glob("delivered-*.ts"))
                generator.retire(cell_dir, {"metrics": cell, "smoke_only": True})
                manifest = json.loads((cell_dir / "media-manifest.json").read_text())
                assert manifest[0]["size_bytes"] > 0
                assert not list(Path(remote["directory"]).glob("delivered-*.ts"))
                records.append({"links": links, "source_endpoints": sorted(endpoints), "metrics": cell,
                                "manifest": manifest, "remote_pids": remote["pids"]})
                print(f"PASS links={links} source_endpoints={len(endpoints)} sink_bytes={manifest[0]['size_bytes']}", flush=True)
        (root / "generator-sockets.json").write_text(json.dumps(wire, indent=2) + "\n")
    result = {
        "source": "local-two-netns-smoke", "qualified": False, "cells": records,
        "sender_sha": args.sender_sha,
        "binary_sha256": {
            name: hashlib.sha256(Path(value).read_bytes()).hexdigest()
            for name, value in (("sender", args.sender), ("receiver", args.receiver), ("sls", args.sls))
        },
    }
    (root / "wire-verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    print("PASS two-netns wire smoke; no provider qualification", flush=True)


if __name__ == "__main__":
    run()
