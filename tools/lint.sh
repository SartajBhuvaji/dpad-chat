#!/bin/sh
# Static checks for every shell script in the repository.
#
# The device runs busybox ash, which is far stricter than bash. `dash -n`
# catches bashisms that bash would silently accept; shellcheck catches the
# rest. Both run in CI.

set -eu

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$REPO_ROOT"

status=0

scripts=$(find app tools tests -name '*.sh' -type f 2>/dev/null | sort)

if [ -z "$scripts" ]; then
    printf 'lint: no shell scripts found\n' >&2
    exit 1
fi

printf 'Checking POSIX syntax (dash -n)\n'
if command -v dash >/dev/null 2>&1; then
    for script in $scripts; do
        if dash -n "$script"; then
            printf '  ok    %s\n' "$script"
        else
            printf '  FAIL  %s\n' "$script"
            status=1
        fi
    done
else
    printf '  skipped: dash not installed\n'
fi

printf '\nChecking shellcheck\n'
if command -v shellcheck >/dev/null 2>&1; then
    # -s sh forces POSIX mode regardless of each file's shebang. $scripts is
    # deliberately unquoted so it splits into one argument per file.
    # shellcheck disable=SC2086
    if shellcheck -s sh -x $scripts; then
        printf '  ok    %s file(s)\n' "$(printf '%s\n' "$scripts" | wc -l | tr -d ' ')"
    else
        status=1
    fi
else
    printf '  skipped: shellcheck not installed\n'
fi

printf '\nChecking executable bits\n'
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
    # Checkouts on a Windows filesystem silently drop the mode bit, which fails
    # only once CI or the device tries to run the file. Assert on the index
    # rather than the working tree, since the index is what gets pushed.
    for entry in app/chat.sh app/launch.sh tests/smoke.sh tests/api.sh \
        tests/net.sh tests/history.sh tests/release.sh tests/install.sh \
        tests/stream.sh tests/screen.sh tests/arrival.py \
        tools/install.sh \
        tools/lint.sh tools/simulate.sh tools/version.sh \
        tools/fetch-cacert.sh tools/make_icon.py tools/mockapi.py \
        tools/package.py; do
        mode=$(git ls-files -s -- "$entry" | cut -d' ' -f1)
        case "$mode" in
            100755)
                printf '  ok    %s\n' "$entry"
                ;;
            '')
                printf '  FAIL  %s (not tracked)\n' "$entry"
                status=1
                ;;
            *)
                printf '  FAIL  %s (mode %s, expected 100755)\n' "$entry" "$mode"
                printf '        fix: git update-index --chmod=+x %s\n' "$entry"
                status=1
                ;;
        esac
    done
else
    printf '  skipped: not a git checkout\n'
fi

printf '\nChecking JSON\n'
if command -v python3 >/dev/null 2>&1; then
    # A malformed manifest makes the app vanish from the Apps menu with no
    # error shown on the device, so this is worth catching here.
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' app/config.json; then
        printf '  ok    app/config.json\n'
    else
        printf '  FAIL  app/config.json\n'
        status=1
    fi
else
    printf '  skipped: python3 not installed\n'
fi

if [ "$status" -eq 0 ]; then
    printf '\nAll checks passed.\n'
else
    printf '\nChecks failed.\n' >&2
fi

exit "$status"
