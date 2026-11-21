# Hermes Island

A macOS menu bar app: double-tap Left Control to talk out loud with an ACP agent (Hermes by default), shown in an island at the top of the screen. Split out of Lip Service on 2026-11-20; it keeps only live talk and call backs.

## Rules

- Never listen on fn or Right Control, and add no dictation. Another app (Hex) owns dictation on the author's Mac.
- `IslandCore/` holds the pure logic and its tests. It must not import AppKit, AVFoundation, CoreGraphics or FluidAudio (`scripts/test.sh` checks).
- Settings stay readable from Lip Service's JSON shape (`IslandSettings`), so the first-launch migration keeps working.
- No network calls besides the pinned model and voice downloads and the user's own voice server.

## Commands

	scripts/fetch-deps.sh && scripts/test.sh && scripts/build-app.sh
	"dist/Hermes Island.app/Contents/MacOS/HermesIsland" --test-talk --preset hermes --host HOST clip.wav

Installed copy: `/Applications/Hermes Island.app`, started at login by the launch agent `com.hunterbohm.hermesisland.agent`. Logs: `log show --predicate 'subsystem == "com.hunterbohm.hermesisland"'`.
