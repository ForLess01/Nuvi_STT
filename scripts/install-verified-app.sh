#!/usr/bin/env bash
# Usage: install-verified-app.sh APP [--destination PATH] [--backup-root PATH]
# Never stops Nuvi forcibly or changes Gatekeeper, quarantine, TCC or keychains.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "Installation failed: $*" >&2; exit 1; }
[ "$#" -ge 1 ] || fail "missing candidate app"
CANDIDATE="$1"; shift
DEST="/Applications/Nuvi.app"
BACKUPS="$HOME/Library/Application Support/Nuvi/Install Backups"
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || fail "missing option value"
    case "$1" in --destination) DEST="$2";; --backup-root) BACKUPS="$2";; *) fail "unknown option: $1";; esac
    shift 2
done
[ "$(basename "$DEST")" = Nuvi.app ] || fail "destination must end in Nuvi.app"
[ ! -L "$DEST" ] || fail "symlink destination is not supported"
PARENT="$(cd "$(dirname "$DEST")" && pwd -P)"
DEST="$PARENT/Nuvi.app"
[ ! -L "$CANDIDATE" ] || fail "symlink candidate is not supported"
CANDIDATE="$(cd "$CANDIDATE" && pwd -P)"
[ "$CANDIDATE" != "$DEST" ] || fail "candidate is already installed"
case "$CANDIDATE/" in "$DEST/"*) fail "candidate cannot be inside destination";; esac
case "$DEST/" in "$CANDIDATE/"*) fail "destination cannot be inside candidate";; esac
quiescent() {
    local result=0
    pgrep -x Nuvi >/dev/null || result=$?
    [ "$result" = 1 ] || fail "quit Nuvi normally before installing (process check status: $result)"
}
quiescent
LOCK="$PARENT/.Nuvi-install.lock"
mkdir "$LOCK" || fail "another installation may be active: $LOCK"
STAGE=""; OLD=""; BACKUP=""; REPLACED=0
finish() {
    local code=$?
    trap - EXIT INT TERM
    if [ "$code" -ne 0 ]; then
        if [ -n "$OLD" ] && [ -d "$OLD" ]; then
            if [ -e "$DEST" ]; then
                mv "$DEST" "$STAGE/rejected-Nuvi.app" || { echo "Recovery required: original retained at $OLD; backup: $BACKUP" >&2; rmdir "$LOCK"; exit "$code"; }
            fi
            if mv "$OLD" "$DEST"; then
                "$ROOT/scripts/verify-app.sh" "$DEST" --compare "$BACKUP" >/dev/null || echo "Recovery verification failed; backup: $BACKUP" >&2
            else echo "Recovery required: original retained at $OLD; backup: $BACKUP" >&2; fi
        elif [ "$REPLACED" = 1 ] && [ -e "$DEST" ]; then
            mv "$DEST" "$STAGE/rejected-Nuvi.app" || echo "Failed candidate retained at $DEST" >&2
        fi
        echo "Installation did not complete. Staging: $STAGE; rollback: $BACKUP" >&2
    elif [ -n "$STAGE" ]; then
        rm -rf "$STAGE"
    fi
    rmdir "$LOCK"
    exit "$code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
REPORT="$("$ROOT/scripts/verify-app.sh" "$CANDIDATE")"
IDENTITY="$(printf '%s\n' "$REPORT" | sed -n 's/^Identity=//p')"
[ -n "$IDENTITY" ] || fail "candidate identity missing"
if [ -e "$DEST" ]; then
    "$ROOT/scripts/verify-app.sh" "$DEST" --identity "$IDENTITY" >/dev/null
    # Resolve existing symlink ancestors and lexical dot segments before mkdir,
    # so rejecting an unsafe backup root cannot mutate either signed app.
    case "$BACKUPS" in /*) rest="${BACKUPS#/}";; *) rest="${PWD#/}/$BACKUPS";; esac
    BACKUPS=/
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        if [ "$rest" = "$part" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$part" in
            ''|.) continue;;
            ..) BACKUPS="$(dirname "$BACKUPS")";;
            *) BACKUPS="${BACKUPS%/}/$part"
               if [ -d "$BACKUPS" ]; then BACKUPS="$(cd "$BACKUPS" && pwd -P)"; fi;;
        esac
    done
    case "$BACKUPS/" in "$DEST/"*|"$CANDIDATE/"*) fail "backup root cannot be inside an app";; esac
    mkdir -p "$BACKUPS"
    BACKUP_DIR="$(mktemp -d "$BACKUPS/rollback.XXXXXX")"
    BACKUP="$BACKUP_DIR/Nuvi.app"
    ditto --rsrc --extattr --acl "$DEST" "$BACKUP"
    "$ROOT/scripts/verify-app.sh" "$BACKUP" --identity "$IDENTITY" --compare "$DEST" >/dev/null
fi
# Same parent volume: both replacement renames are local, not cross-volume copies.
STAGE="$(mktemp -d "$PARENT/.Nuvi-install.XXXXXX")"
ditto --rsrc --extattr --acl "$CANDIDATE" "$STAGE/Nuvi.app"
"$ROOT/scripts/verify-app.sh" "$STAGE/Nuvi.app" --identity "$IDENTITY" --compare "$CANDIDATE" >/dev/null
quiescent
if [ -e "$DEST" ]; then
    # Revalidate immediately before moving the original, after staging completes.
    "$ROOT/scripts/verify-app.sh" "$BACKUP" --identity "$IDENTITY" --compare "$DEST" >/dev/null
    OLD="$STAGE/previous-Nuvi.app"
    mv "$DEST" "$OLD"
fi
mv "$STAGE/Nuvi.app" "$DEST"
REPLACED=1
"$ROOT/scripts/verify-app.sh" "$DEST" --identity "$IDENTITY" --compare "$CANDIDATE" >/dev/null
if [ -n "$OLD" ]; then "$ROOT/scripts/verify-app.sh" "$BACKUP" --identity "$IDENTITY" --compare "$OLD" >/dev/null; fi
echo "==> Installed and verified: $DEST"
[ -z "$BACKUP" ] || echo "Rollback: $BACKUP"
echo "Launch with: open \"$DEST\""
