#!/usr/bin/env python3
"""Build the release archives.

Both carry an ``App/DPadChat/`` prefix so they unpack straight onto the root of
an Onion SD card, the way every other community app is distributed. A release
that is only a tag makes people clone a repository to install a shell script.

Two formats, for two audiences. The zip is what a person downloads and unpacks
on a desktop. The tarball is what the app's own /update fetches: busybox always
has tar and gzip, while unzip is an optional applet that may not be on the
device at all, and discovering that after the download is too late.

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
import gzip
import io
import pathlib
import re
import stat
import sys
import tarfile
import zipfile

APP_NAME = "DPadChat"

# Anything not listed here is copied with default permissions.
EXECUTABLE = {"launch.sh", "chat.sh", "apply-update.sh"}

# Runtime state: the API key and the transcript. Shipping it would leak a
# developer's key into a public release.
EXCLUDED_DIRS = {"data"}

REQUIRED = [
    "config.json",
    "launch.sh",
    "chat.sh",
    # Without this in the archive an update stages and then declines to install
    # itself, which is a confusing way to find out the packaging is wrong.
    "apply-update.sh",
    "res/cacert.pem",
    "res/icon.png",
]

# Fixed timestamp so two builds of the same tree produce identical archives.
# Zero would be 1970, which some extractors treat as corrupt.
EPOCH = (2024, 1, 1, 0, 0, 0)


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


def mode_for(relative: pathlib.Path) -> int:
    """Permissions are set here rather than copied from the checkout.

    The repository is often cloned onto a Windows filesystem, which does not
    record an executable bit at all, so inheriting it would ship an app the
    device cannot launch.
    """
    mode = stat.S_IRUSR | stat.S_IWUSR | stat.S_IRGRP | stat.S_IROTH
    if relative.name in EXECUTABLE:
        mode |= stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    return mode


def build_zip(app_dir: pathlib.Path, files: list[pathlib.Path], archive: pathlib.Path) -> None:
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for relative in files:
            info = zipfile.ZipInfo(f"App/{APP_NAME}/{relative.as_posix()}", date_time=EPOCH)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = mode_for(relative) << 16
            zf.writestr(info, (app_dir / relative).read_bytes())


def build_tar(app_dir: pathlib.Path, files: list[pathlib.Path], archive: pathlib.Path) -> None:
    # mtime is pinned and gzip's own timestamp suppressed, so the same tree
    # always produces byte-identical output. An updater comparing checksums
    # across builds depends on that being true.
    with archive.open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode="w") as tf:  # type: ignore[arg-type]
                for relative in files:
                    payload = (app_dir / relative).read_bytes()
                    info = tarfile.TarInfo(f"App/{APP_NAME}/{relative.as_posix()}")
                    info.size = len(payload)
                    info.mode = mode_for(relative)
                    info.mtime = 0
                    info.uid = info.gid = 0
                    info.uname = info.gname = "root"
                    tf.addfile(info, io.BytesIO(payload))


def main() -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=pathlib.Path, default=repo_root / "dist")
    args = parser.parse_args()

    app_dir = repo_root / "app"
    version = read_version(repo_root)
    files = collect(app_dir)
    verify(app_dir, files)

    args.output_dir.mkdir(parents=True, exist_ok=True)

    for suffix, builder in ((".zip", build_zip), (".tar.gz", build_tar)):
        archive = args.output_dir / f"{APP_NAME}-v{version}{suffix}"
        if archive.exists():
            archive.unlink()
        builder(app_dir, files, archive)
        size_kb = archive.stat().st_size / 1024
        print(f"Wrote {archive} ({len(files)} files, {size_kb:.0f} KB)")

    print("Unzip onto the root of the SD card.")


if __name__ == "__main__":
    main()
