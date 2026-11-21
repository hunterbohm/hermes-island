# Security

Report a security problem in Hermes Island through
[private vulnerability reporting](https://github.com/hunterbohm/hermes-island/security/advisories/new),
not in a public issue.

Include the app version (menu bar item > About, or `defaults read "/Applications/Hermes Island.app/Contents/Info" CFBundleShortVersionString`),
your macOS version, and the steps to reproduce. Of most interest: anything that records or sends audio or keys,
runs a command the user did not allow, or reaches the network outside the pinned model downloads.
