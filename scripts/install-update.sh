#!/bin/bash
# Replaces the installed Hermes Island with a downloaded, already-checked release and starts it again.
# Usage: install-update.sh NEW_APP DEST_APP OLD_PID WORK_DIR STATUS_FILE
# The app runs a copy of this from a one-shot launchd job (see Updater.swift) after it has checked the release and
# quit. It waits for OLD_PID to exit, swaps the bundle, and starts the new copy, then writes its own exit code to
# STATUS_FILE and removes WORK_DIR. Whatever goes wrong, it opens the app in DEST_APP so one copy is running.
#
# The login-item part is the sequence `install()` in hermes-plugin/island.py measured on macOS 26: the login item's record
# pins the build it was registered with, and launchd refuses a different one (OS_REASON_CODESIGNING) until the new build
# has been opened while the item is on and the item has been turned off and on again with LaunchServices reading the
# bundle in between.
set -uo pipefail
umask 077
new_app="$1" dest="$2" old_pid="$3" work="$4" status_file="$5"
open_bin="${HERMES_ISLAND_OPEN:-/usr/bin/open}"
lsregister="${HERMES_ISLAND_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
launchctl_bin="${HERMES_ISLAND_LAUNCHCTL:-launchctl}"
settle="${HERMES_ISLAND_SETTLE:-5}"
agent="dev.hermes-island.app.agent"
binary="$dest/Contents/MacOS/HermesIsland"
fresh="$(dirname "$dest")/.Hermes Island.new.app"
aside="$(dirname "$dest")/.Hermes Island.old.app"

login_off=0  # 1 while this script has turned Open at Login off and not yet back on
finish() {
    code=$?
    if [[ $code != 0 ]]; then
        # A failed install must leave the app and its login setting as they were.
        [[ $login_off == 1 && -x "$binary" ]] && "$binary" --open-at-login on >/dev/null 2>&1
        "$open_bin" "$dest" >/dev/null 2>&1 || true
    fi
    printf '%s\n' "$code" > "$status_file"
    rm -rf "$work" "$fresh" "$aside"
    printf 'Finished %s with exit %s\n' "$(date)" "$code"
}
trap finish EXIT
printf 'Installing %s into %s, %s\n' "$new_app" "$dest" "$(date)"

app() { "$binary" "$@" 2>/dev/null; }
# Copies of the destination app running now: matched by the path of its binary, so another copy is left alone.
copies() { pgrep -f "^$dest/Contents/MacOS/HermesIsland" || true; }
wait_until() { # SECONDS COMMAND...
    local seconds="$1" tick; shift
    for ((tick = 0; tick < seconds * 2; tick++)); do "$@" && return 0; sleep 0.5; done
    "$@"
}
gone() { ! kill -0 "$old_pid" 2>/dev/null; }
no_copies() { [[ -z "$(copies)" ]]; }
launchd_runs_it() { "$launchctl_bin" print "gui/$(id -u)/$agent" 2>/dev/null | grep -qE '^[[:space:]]*pid = '; }

wait_until 30 gone || { printf 'Hermes Island (pid %s) did not quit; nothing was changed.\n' "$old_pid" >&2; exit 1; }

login=0
if [[ -x "$binary" ]] && app --login-status | grep -qF 'launch agent: enabled'; then login=1; fi
if [[ $login == 1 ]]; then login_off=1; app --open-at-login off >/dev/null; fi

# The new bundle is assembled beside the old one and renamed into place: writing over a running app's binary kills it.
rm -rf "$fresh" "$aside"
/usr/bin/ditto "$new_app" "$fresh" || { printf 'Could not copy the new app beside %s.\n' "$dest" >&2; exit 1; }
if [[ -e "$dest" ]]; then mv "$dest" "$aside" || { printf 'Could not move %s aside.\n' "$dest" >&2; exit 1; }; fi
if ! mv "$fresh" "$dest"; then
    printf 'Could not put the new app in %s; putting the old one back.\n' "$dest" >&2
    [[ -e "$aside" ]] && mv "$aside" "$dest"
    exit 1
fi
rm -rf "$aside"
"$lsregister" -f -R "$dest" >/dev/null 2>&1 || true

if [[ $login == 0 ]]; then
    "$open_bin" "$dest" || exit 1
    printf 'Started the new copy.\n'
    exit 0
fi

app --open-at-login on >/dev/null
for _ in 1 2 3; do
    "$open_bin" "$dest" >/dev/null 2>&1 || true
    sleep "$settle"
    stayed="$(copies)"
    [[ -z "$stayed" ]] && break  # it handed over to the login item, which is the step that matters
    for pid in $stayed; do kill -TERM "$pid" 2>/dev/null || true; done  # the copy just opened, which ran by itself instead
    wait_until 5 no_copies
done
app --open-at-login off >/dev/null
"$lsregister" -u "$dest" >/dev/null 2>&1 || true
sleep "$((settle / 2 + 1))"
"$lsregister" -f -R "$dest" >/dev/null 2>&1 || true
sleep "$((settle / 2 + 1))"
app --open-at-login on >/dev/null
login_off=0
if ! wait_until 10 launchd_runs_it; then
    printf 'The login item would not start the new copy; it was opened by hand. Turn Open at Login off and on in its menu.\n' >&2
    exit 1
fi
printf 'Started the new copy through the login item.\n'
