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

printf '\nChecking JSON\n'
if command -v python3 >/dev/null 2>&1; then
    for json in app/config.json; do
        if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json"; then
            printf '  ok    %s\n' "$json"
        else
            printf '  FAIL  %s\n' "$json"
            status=1
        fi
    done
else
    printf '  skipped: python3 not installed\n'
fi

if [ "$status" -eq 0 ]; then
    printf '\nAll checks passed.\n'
else
    printf '\nChecks failed.\n' >&2
fi

exit "$status"
