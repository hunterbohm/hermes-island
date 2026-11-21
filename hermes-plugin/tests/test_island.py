"""Tests for island.py against a fake HermesIsland. Run: python3 -m unittest discover -s hermes-plugin/tests"""

import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("island", HERE / "island.py")
island = importlib.util.module_from_spec(spec)
sys.modules["island"] = island
spec.loader.exec_module(island)

FAKE = """#!/bin/sh
if [ "$1" = --help ]; then echo 'HermesIsland call --about TEXT' >&2; echo 'HermesIsland agent [--hermes]' >&2; exit 0; fi
printf '%s\\n' "$@" > "$0.args"
cat > "$0.stdin"
case "$1" in
  call) echo '{"status":"ringing"}'; echo '{"status":"missed","detail":"nobody answered"}'; exit 3 ;;
  agent) echo '{"agent":{"name":"Hermes","command":["hermes","acp"],"host":null}}' ;;
esac
"""


class IslandTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.app = Path(self.folder.name) / "HermesIsland"
        self.app.write_text(FAKE)
        self.app.chmod(self.app.stat().st_mode | stat.S_IEXEC)
        self.darwin = mock.patch.object(island.platform, "system", return_value="Darwin")
        self.darwin.start()

    def tearDown(self):
        self.darwin.stop()
        self.folder.cleanup()

    def test_a_call_passes_the_result_on_stdin_and_returns_the_last_status(self):
        outcome = island.call_back(island.Island(app=str(self.app)), "the flight search", "Two flights under $300.", 500)
        self.assertEqual(outcome["status"], "missed")
        self.assertEqual(outcome["exit_code"], 3)
        self.assertEqual(outcome["next"], "text instead")
        args = Path(str(self.app) + ".args").read_text().splitlines()
        self.assertEqual(args, ["call", "--from", "Hermes", "--about", "the flight search", "--ring", "120"])
        self.assertEqual(Path(str(self.app) + ".stdin").read_text(), "Two flights under $300.")

    def test_a_call_without_a_result_does_not_ring(self):
        outcome = island.call_back(island.Island(app=str(self.app)), "x", "  ")
        self.assertEqual(outcome["exit_code"], 2)
        self.assertFalse(Path(str(self.app) + ".args").exists())

    def test_no_app_and_no_transport_says_so(self):
        outcome = island.call_back(island.Island(app="/nowhere/HermesIsland"), "x", "y")
        self.assertEqual(outcome["status"], "failed")
        self.assertIn("not installed", outcome["detail"])

    def test_off_macos_without_a_transport_there_is_no_island(self):
        with mock.patch.object(island.platform, "system", return_value="Linux"):
            self.assertIn("transport", island.Island(app=str(self.app)).missing())

    def test_a_transport_gets_one_quoted_remote_command(self):
        reach = island.Island.from_settings({"transport": "ssh -o BatchMode=yes my-mac", "app_path": ""}.get)
        command = reach.command(["call", "--about", "it's done; rm -rf /"])
        self.assertEqual(command[:3], ["ssh", "-o", "BatchMode=yes"])
        self.assertEqual(command[3], "my-mac")
        self.assertEqual(len(command), 5)
        self.assertIn("'it'\"'\"'s done; rm -rf /'", command[4])
        self.assertIsNone(reach.missing())

    def test_setup_runs_the_apps_agent_command(self):
        code, out = island.setup(island.Island(app=str(self.app)), "home-mac")
        self.assertEqual(code, 0)
        self.assertEqual(Path(str(self.app) + ".args").read_text().splitlines(), ["agent", "--hermes", "--host", "home-mac"])
        self.assertEqual(json.loads(out)["agent"]["name"], "Hermes")

    def test_an_older_app_is_never_sent_a_command_it_would_take_for_a_launch(self):
        self.app.write_text("#!/bin/sh\necho usage >&2\nprintf '%s\\n' \"$@\" >> \"$0.args\"\n")
        older = island.Island(app=str(self.app))
        self.assertIn("too old", island.call_back(older, "x", "y")["detail"])
        self.assertEqual(island.setup(older, None)[0], 1)
        self.assertEqual(Path(str(self.app) + ".args").read_text().split(), ["--help", "--help"])

    def test_the_source_is_the_repository_around_the_plugin(self):
        self.assertEqual(island.source_checkout(HERE), HERE.parent)


if __name__ == "__main__":
    unittest.main()
