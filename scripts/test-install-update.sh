#!/bin/bash
# Checks install-update.sh with fake apps, a fake `open`, `lsregister` and `launchctl`, so nothing real is touched: the
# swap, the rollback when something fails, a copy that has not quit, and the order of the login item steps.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/install-update.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
check() { # NAME CONDITION-EXIT-CODE
    if [[ "$2" == 0 ]]; then printf 'pass  %s\n' "$1"; else printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); fi
}

# A fake app whose binary logs what it is asked and keeps a login state in $STATE/login.
make_app() { # PATH MARKER
    mkdir -p "$1/Contents/MacOS"
    cat > "$1/Contents/MacOS/HermesIsland" <<APP
#!/bin/bash
echo "$2 \$*" >> "\$CALLS"
case "\$1" in
    --login-status) if [[ -f "\$STATE/login" ]]; then echo "launch agent: enabled"; else echo "launch agent: notRegistered"; fi ;;
    --open-at-login) if [[ "\$2" == on ]]; then touch "\$STATE/login"; else rm -f "\$STATE/login"; fi ;;
esac
APP
    chmod 755 "$1/Contents/MacOS/HermesIsland"
    printf '%s' "$2" > "$1/marker"
}
for fake in open lsregister launchctl; do
    cat > "$tmp/$fake" <<FAKE
#!/bin/bash
echo "$fake \$*" >> "\$CALLS"
FAKE
    chmod 755 "$tmp/$fake"
done
# launchd reports a running pid for the agent, as it does once the login item starts the new copy.
cat > "$tmp/launchctl" <<'FAKE'
#!/bin/bash
echo "launchctl $*" >> "$CALLS"
echo "	pid = 4242"
FAKE
chmod 755 "$tmp/launchctl"

run() { # NAME LOGIN(0|1) [NEW_APP] [OLD_PID]
    case="$tmp/$1"
    rm -rf "$case"; mkdir -p "$case/Applications" "$case/state" "$case/work"
    export CALLS="$case/calls" STATE="$case/state"
    : > "$CALLS"
    make_app "$case/Applications/Hermes Island.app" OLD
    mkdir -p "$case/work/unpacked"
    make_app "$case/work/unpacked/Hermes Island.app" NEW
    [[ "$2" == 1 ]] && touch "$STATE/login"
    new="${3:-$case/work/unpacked/Hermes Island.app}"
    HERMES_ISLAND_OPEN="$tmp/open" HERMES_ISLAND_LSREGISTER="$tmp/lsregister" HERMES_ISLAND_LAUNCHCTL="$tmp/launchctl" \
        HERMES_ISLAND_SETTLE=0 /bin/bash "$script" "$new" "$case/Applications/Hermes Island.app" "${4:-999999}" "$case/work" "$case/status" \
        > "$case/out" 2>&1
    code=$?
}
marker() { cat "$case/Applications/Hermes Island.app/marker"; }

run swap 0
check "the new app replaces the old and the script succeeds" $([[ "$code" == 0 && "$(marker)" == NEW ]]; echo $?)
check "it writes 0 to the status file and removes the work folder" $([[ "$(cat "$case/status")" == 0 && ! -e "$case/work" ]]; echo $?)
check "it starts the new copy once and leaves no copy beside it" $([[ "$(grep -c '^open ' "$case/calls")" == 1 && ! -e "$case/Applications/.Hermes Island.old.app" && ! -e "$case/Applications/.Hermes Island.new.app" ]]; echo $?)
check "with Open at Login off it never touches the login item" $(! grep -q -e '--open-at-login' "$case/calls"; echo $?)

run missing 0 "$tmp/nowhere.app"
check "a missing new app leaves the old one in place, opens it, and fails" $([[ "$code" != 0 && "$(marker)" == OLD && "$(cat "$case/status")" != 0 ]] && grep -q '^open ' "$case/calls"; echo $?)

run running 0 "" "$$"
check "a copy that has not quit changes nothing and fails" $([[ "$code" != 0 && "$(marker)" == OLD ]]; echo $?)

run login 1
steps="$(grep -E -e '--login-status|--open-at-login|^open |^lsregister' "$case/calls" | sed -E 's/^(OLD|NEW) //; s# /.*##' | tr '\n' ',')"
check "with Open at Login on the old app turns it off and the new one turns it back on" $([[ "$code" == 0 && "$(marker)" == NEW && -f "$STATE/login" ]]; echo $?)
check "the login steps run in the order macOS 26 needs" $([[ "$steps" == "--login-status,--open-at-login off,lsregister -f -R,--open-at-login on,open,--open-at-login off,lsregister -u,lsregister -f -R,--open-at-login on," ]]; echo $?)
check "the first login steps run on the old app and the rest on the new" $(sed -n '1,2p' "$case/calls" | grep -qv '^NEW' && grep -q '^NEW --open-at-login on' "$case/calls"; echo $?)

run loginfail 1 "$tmp/nowhere.app"
check "a failed install with Open at Login on turns it back on and keeps the old app" $([[ "$code" != 0 && "$(marker)" == OLD && -f "$STATE/login" ]] && grep -q '^OLD --open-at-login on' "$case/calls"; echo $?)

[[ "$failures" == 0 ]] && echo "all checks passed" || { echo "$failures failed" >&2; exit 1; }
