"""Controller loss during generator teardown, synchronized on the child's signal."""

from __future__ import annotations

import json
import os
import selectors
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import capacity_live
from capacity_remote_test_support import config_for


class TeardownTests:
    def test_controller_drop_during_finish_and_stop_reaps_stubborn_publisher(self) -> None:
        for operation in ("finish", "stop"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                fifo = root / "terminating"
                os.mkfifo(fifo)
                descriptor = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
                config = config_for(root)
                config["load"]["argv"] = [
                    sys.executable, "-c",
                    "import os,signal,sys\n"
                    "fd=os.open(sys.argv[1],os.O_WRONLY)\n"
                    "signal.signal(signal.SIGTERM,lambda *_:os.write(fd,b'TERM\\n'))\n"
                    "print('total_size=1316',flush=True)\n"
                    "while True:signal.pause()\n",
                    str(fifo),
                ]
                worker = Path(capacity_live.__file__).with_name("capacity_generator.py")
                owned = []
                pidfds = []
                with (root / "worker.log").open("wb") as log, selectors.DefaultSelector() as selector:
                    child = subprocess.Popen(
                        [sys.executable, str(worker)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=log, start_new_session=True,
                    )
                    try:
                        def send(request):
                            child.stdin.write((json.dumps(request) + "\n").encode())
                            child.stdin.flush()

                        def response():
                            with selectors.DefaultSelector() as replies:
                                replies.register(child.stdout, selectors.EVENT_READ)
                                self.assertTrue(replies.select(10), "worker control response timed out")
                            document = json.loads(child.stdout.readline())
                            self.assertNotIn("error", document)
                            return document

                        send({"operation": "hello", "config": config})
                        response()
                        send({"operation": "prepare", "label": "drop", "bonds": 1, "bitrate": 6, "links": 1})
                        owned = response()["pids"]
                        send({"operation": "start"})
                        response()
                        pidfds = [os.pidfd_open(pid) for pid in owned]
                        for pid, pidfd in zip(owned, pidfds):
                            selector.register(pidfd, selectors.EVENT_READ, pid)
                        with selectors.DefaultSelector() as terminating:
                            terminating.register(descriptor, selectors.EVENT_READ)
                            send({"operation": operation})
                            self.assertTrue(terminating.select(10), "publisher never received SIGTERM")
                            self.assertEqual(os.read(descriptor, 4096), b"TERM\n")
                            # The owner is now inside close(), not its idle request loop.
                            child.stdin.close()
                        returncode = child.wait(timeout=15)
                        exited = {key.data for key, _ in selector.select(0)}
                        survivors = [pid for pid in owned if pid not in exited]
                        self.assertEqual(survivors, [], f"worker_exit={returncode}; surviving owned pids={survivors}")
                        self.assertEqual(returncode, 0)
                    finally:
                        for pid in owned:
                            try:
                                os.killpg(pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                        if child.poll() is None:
                            os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=10)
                        child.stdin.close()
                        child.stdout.close()
                        for pidfd in pidfds:
                            os.close(pidfd)
                        os.close(descriptor)


class TeardownCases(TeardownTests, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()
