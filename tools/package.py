#!/usr/bin/env python3
"""Build the release archive.

The zip carries an ``App/DPadChat/`` prefix so it unpacks straight onto the root
of an Onion SD card, the way every other community app is distributed. A release
that is only a tag makes people clone a repository to install a shell script.

Python rather than the zip(1) utility for two reasons: it is already a
dependency of the icon generator and the mock server, so contributors need
nothing new, and zip(1) is absent from plenty of minimal images. It also lets
the executable bits be set explicitly instead of inherited from a checkout,
which matters because the repository is often cloned onto a Windows filesystem
that does not record them.

    python3 tools/package.py [--output-dir dist]
"""

from __future__ import annotations

import argparse
import pathlib
import re
import stat
import sys
import zipfile

APP_NAME = "DPadChat"

# Anything not listed here is copied with default permissions.
EXECUTABLE = {"launch.sh", "chat.sh"}

# Runtime state: the API key and the transcript. Shipping it would leak a
# developer's key into a public release.
EXCLUDED_DIRS = {"data"}

REQUIRED = ["config.json", "launch.sh", "chat.sh", "res/cacert.pem", "res/icon.png"]


def read_version(repo_root: pathlib.Path) -> str:
    source = (repo_root / "app/lib/common.sh").read_text()
    match = re.search(r"^DPADCHAT_VERSION='([^']+)'", source, re.MULTILINE)
    if not match:
        sys.exit("package: no DPADCHAT_VERSION in app/lib/common.sh")
    return match.group(1)


def collect(app_dir: pathlib.Path) -> list[pathlib.Path]:
    files = []
    for path in sorted(app_dir.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(app_dir)
        if EXCLUDED_DIRS.intersection(relative.parts):
            continue
        files.append(relative)
    return files


def verify(app_dir: pathlib.Path, files: list[pathlib.Path]) -> None:
    names = {str(f) for f in files}

    missing = [name for name in REQUIRED if name not in names]
    if missing:
        # The CA bundle in particular is not optional: without it the app
        # refuses every https request rather than falling back to unverified.
        sys.exit(f"package: missing from the app directory: {', '.join(missing)}")

    leaked = [name for name in names if name.startswith("data/")]
    if leaked:
        sys.exit(f"package: runtime data leaked into the package: {leaked}")

    del app_dir


def build(app_dir: pathlib.Path, files: list[pathlib.Path], archive: pathlib.Path) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    if archive.exists():
        archive.unlink()

    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for relative in files:
            source = app_dir / relative
            arcname = f"App/{APP_NAME}/{relative.as_posix()}"

            info = zipfile.ZipInfo(arcname)
            info.compress_type = zipfile.ZIP_DEFLATED

            mode = stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH
            if relative.name in EXECUTABLE:
                mode |= stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
            info.external_attr = mode << 16

            zf.writestr(info, source.read_bytes())


def main() -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=pathlib.Path, default=repo_root / "dist")
    args = parser.parse_args()

    app_dir = repo_root / "app"
    version = read_version(repo_root)
    files = collect(app_dir)
    verify(app_dir, files)

    archive = args.output_dir / f"{APP_NAME}-v{version}.zip"
    build(app_dir, files, archive)

    size_kb = archive.stat().st_size / 1024
    print(f"Wrote {archive} ({len(files)} files, {size_kb:.0f} KB)")
    print("Unzip onto the root of the SD card.")


if __name__ == "__main__":
    main()
