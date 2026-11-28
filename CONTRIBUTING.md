# Contributing

Bug reports and pull requests are welcome.

- Build and test as the README says: `scripts/fetch-deps.sh && scripts/test.sh && scripts/build-app.sh`. Plugin changes also run `python3 -m unittest discover -s hermes-plugin/tests` and `hermes plugins validate hermes-plugin`.
- Pure logic goes in `IslandCore/`, with a test. It must not import AppKit, AVFoundation, CoreGraphics or FluidAudio.
- The app never listens on fn or Right Control, adds no dictation, and goes online only for the pinned model and voice downloads and a signed release's once-a-day update check. A change that needs more should say why in the pull request.
- Keep your own hosts, accounts and paths out of code and tests. Use made-up ones such as `my-mac` or `you@example.com`.
- One change per pull request, with a short note on how you checked it.

Report security problems privately, as [SECURITY.md](.github/SECURITY.md) says.
