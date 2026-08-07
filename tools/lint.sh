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

printf '\nChecking shellcheck directive comments\n'
# A comment whose first word is "shellcheck" is read as a directive. Prose there
# is a parse error that makes the entire file unanalysable, and the only sign is
# an SC1094 on whatever sourced it, so real findings hide behind it.
# shellcheck disable=SC2086
directive_prose=$(grep -nE '^[[:space:]]*#[[:space:]]*shellcheck[[:space:]]' $scripts |
    grep -vE 'shellcheck (disable|enable|source|source-path|shell|external-sources)=' || true)
if [ -n "$directive_prose" ]; then
    printf '%s\n' "$directive_prose" | while IFS= read -r offender; do
        printf '  FAIL  %s\n' "$offender"
    done
    printf '        reword so the comment does not begin with "shellcheck"\n'
    status=1
else
    printf '  ok    no prose comments read as directives\n'
fi

printf '\nChecking line endings\n'
# A CR at the end of `#!/bin/sh` makes the kernel look for an interpreter named
# "/bin/sh\r", which does not exist. busybox reports that as "not found" for a
# file that is plainly there, so the search starts at paths and permissions and
# never gets near the real cause. A checkout on a Windows filesystem is where
# the CRs come from; .gitattributes prevents it and this catches it anyway,
# because the working tree can be rewritten by anything.
carriage=''
for script in $scripts; do
    if grep -q "$(printf '\r')" "$script" 2>/dev/null; then
        carriage="$carriage $script"
    fi
done
if [ -n "$carriage" ]; then
    for offender in $carriage; do
        printf '  FAIL  %s (carriage returns)\n' "$offender"
    done
    printf '        fix: git checkout -- . after confirming .gitattributes is present\n'
    status=1
else
    printf '  ok    no carriage returns in %s file(s)\n' \
        "$(printf '%s\n' "$scripts" | wc -l | tr -d ' ')"
fi

printf '\nChecking executable bits\n'
if command -v git >/dev/null 2>&1 && [ -d .git ]; then
    # Checkouts on a Windows filesystem silently drop the mode bit, which fails
    # only once CI or the device tries to run the file. Assert on the index
    # rather than the working tree, since the index is what gets pushed.
    for entry in app/chat.sh app/launch.sh app/apply-update.sh app/uninstall.sh \
        tests/smoke.sh tests/api.sh \
        tests/net.sh tests/history.sh tests/release.sh tests/install.sh \
        tests/stream.sh tests/screen.sh tests/update.sh tests/uninstall.sh \
        tests/arrival.py \
        tests/input.sh tests/keys.py \
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
