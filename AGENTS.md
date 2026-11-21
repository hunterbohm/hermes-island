# Hermes Island

A macOS menu bar app: double-tap Left Control to talk out loud with an ACP agent (Hermes by default), shown in an island at the top of the screen. It began as the live talk feature of Lip Service and keeps only live talk and call backs. `hermes-plugin/` is the Hermes plugin that rings the island and sets the app up.

## Rules

- Never listen on fn or Right Control, and add no dictation, so the app runs beside any dictation app.
- `IslandCore/` holds the pure logic and its tests. It must not import AppKit, AVFoundation, CoreGraphics or FluidAudio (`scripts/test.sh` checks).
- Settings stay readable from Lip Service's JSON shape (`IslandSettings`), so the first-launch migration keeps working.
- No network calls besides the pinned model and voice downloads and the user's own voice server.
- No personal names, hosts, handles or paths in code, defaults, tests or docs. A user's own values live in their settings.

## Commands

	scripts/fetch-deps.sh && scripts/test.sh && scripts/build-app.sh
	"dist/Hermes Island.app/Contents/MacOS/HermesIsland" --test-talk --preset hermes --host HOST clip.wav
	python3 -m unittest discover -s hermes-plugin/tests

Installed copy: `/Applications/Hermes Island.app`, started at login by the launch agent `dev.hermes-island.app.agent`. Logs: `log show --predicate 'subsystem == "dev.hermes-island.app"'`.

To put a new build in /Applications, use `hermes island build --install` or `install()` in `hermes-plugin/island.py`, not a plain copy: macOS 26's login item record pins the build it was registered with, and a plain copy leaves launchd refusing the new one (`OS_REASON_CODESIGNING`, launch constraint), so the app would not start at the next login.
