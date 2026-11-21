"""Tests for island.py against a fake HermesIsland. Run: python3 -m unittest discover -s hermes-plugin/tests"""

import importlib.util
import json
import os
import stat
import subprocess
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

    def installed_as(self, record):
        plugins = Path(self.folder.name) / "plugins"
        (plugins / "hermes-island").mkdir(parents=True)
        (plugins / ".install-metadata.json").write_text(json.dumps({"hermes-island": record}))
        return plugins / "hermes-island"

    def test_a_catalog_install_names_the_pinned_commit(self):
        plugin = self.installed_as({"revision": "a" * 40, "catalog": {"name": "hermes-island", "sha": "B" * 40}})
        self.assertEqual(island.installed_commit(plugin), "b" * 40)

    def test_a_git_install_names_the_commit_it_checked_out(self):
        self.assertEqual(island.installed_commit(self.installed_as({"revision": "c" * 40})), "c" * 40)

    def test_a_copied_plugin_names_no_commit(self):
        self.assertIsNone(island.installed_commit(HERE))
        self.assertIsNone(island.installed_commit(self.installed_as({"revision": "main"})))

    def test_the_source_is_fetched_at_exactly_the_commit(self):
        repo = Path(self.folder.name) / "repo"
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        (repo / "scripts").mkdir()
        (repo / "scripts" / "build-app.sh").write_text("first\n")
        subprocess.run(git + ["add", "."], check=True)
        subprocess.run(git + ["commit", "-qm", "one"], check=True)
        first = subprocess.run(git + ["rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        (repo / "scripts" / "build-app.sh").write_text("second\n")
        subprocess.run(git + ["commit", "-qam", "two"], check=True)
        cache = Path(self.folder.name) / "cache"
        with mock.patch.object(island, "REPO", repo.as_uri()):
            root, _ = island.fetch_source(first, cache)
            self.assertEqual((root / "scripts" / "build-app.sh").read_text(), "first\n")
            self.assertEqual(island.fetch_source(first, cache)[0], root)
            missing, message = island.fetch_source("d" * 40, cache)
        self.assertIsNone(missing)
        self.assertFalse((cache / ("d" * 40)).exists())


if __name__ == "__main__":
    unittest.main()
