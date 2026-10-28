#!/usr/bin/python3
"""Repair only the local, unmounted OrbStack data directory; never its NFS view."""
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


def repair_unmounted_directory(path):
    path = os.path.abspath(path)
    def mount_table():
        return subprocess.run(["/sbin/mount"], check=True, timeout=3,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout

    def ensure_unmounted(table):
        # Read the kernel table before target lookup. Decode mount's octal path
        # escapes rather than touching a potentially unavailable mounted view.
        for line in table.splitlines():
            match = re.search(r" on (.+) \(([^)]+)\)", line)
            if not match:
                continue
            target = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), match[1])
            if target == path:
                raise RuntimeError("mounted directory protected; OrbStack start prohibited")
            if path.startswith(target.rstrip("/") + "/") and any(
                    kind in match[2].split(",")[0].lower() for kind in ("nfs", "smb", "fuse", "webdav")):
                raise RuntimeError("data directory is on a nonlocal filesystem")

    ensure_unmounted(mount_table())
    parent = Path(path).parent
    parent_device = os.stat(parent).st_dev
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(fd)
        # A mount racing the open cannot cause chmod on an NFS filesystem.
        # Once opened, fchmod refers to this inode, even if a mount arrives later.
        if info.st_dev != parent_device:
            raise RuntimeError("directory is not on its parent's local filesystem")
        if info.st_uid != os.getuid() or not stat.S_ISDIR(info.st_mode):
            raise RuntimeError("directory is not owned by current user")
        ensure_unmounted(mount_table())
        if not info.st_mode & stat.S_IWUSR:
            os.fchmod(fd, stat.S_IMODE(info.st_mode) | stat.S_IWUSR)
            return "unmounted local owner-write permission repaired"
        return "unmounted local permissions unchanged"
    finally:
        os.close(fd)


if __name__ == "__main__":
    print(repair_unmounted_directory(sys.argv[1]))
