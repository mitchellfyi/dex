"""Private-file primitives shared by the mission ledger, the memory store and the feedback outbox.

Three scripts write small JSON records that must survive a crash and must not
be trusted once they stop being the user's own private regular files. They had
three copies of the same writer; the copies live here now.

    atomic_write(path, text)     mkstemp in the target directory, fchmod 0600,
                                 write, fsync, os.replace
    append_line(path, line)      O_APPEND|O_CREAT at 0600, one write, fsync
    private_file_ok(path)        True when path is a regular, non-link file owned
                                 by this user with no group/other bits; False
                                 when absent; raises PrivateFileError otherwise

Standard library only.
"""

import os
import stat
import tempfile


class PrivateFileError(Exception):
    """The file exists but is not a private regular file of this user."""


def private_file_ok(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(info.st_mode):
        raise PrivateFileError(f"{path}: symlinks are not trusted")
    if not stat.S_ISREG(info.st_mode):
        raise PrivateFileError(f"{path}: not a regular file")
    if info.st_uid != os.getuid():
        raise PrivateFileError(f"{path}: owned by another user")
    if info.st_mode & 0o077:
        raise PrivateFileError(f"{path}: not private (mode {oct(info.st_mode & 0o777)})")
    return True


def atomic_write(path, text, prefix=".tmp."):
    directory = os.path.dirname(path) or "."
    descriptor, temporary = tempfile.mkstemp(prefix=prefix, dir=directory)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            descriptor = -1
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary:
            try:
                os.unlink(temporary)
            except OSError:
                pass


def append_line(path, line):
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(descriptor, (line + "\n").encode("utf-8"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
