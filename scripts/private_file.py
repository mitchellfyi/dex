"""Read a file that only this user may have written, without being raced.

The review ledger and its receipts are the record of what a review actually
did. Reading one is not `open().read()`: the file has to still be the file that
was checked, and the check has to mean something.

So every read here passes the same gauntlet:

  * lstat, not stat — a symlink is not the file it points at.
  * A regular file, owned by this euid, mode exactly 0600. Anything a second
    party can write is not a private record.
  * A size within bounds before reading, and again after: a file that grew
    while being read was being written by somebody.
  * O_NOFOLLOW on open, then fstat against the lstat: same device and inode, or
    the path was swapped between the two calls.
  * fstat again at the end, comparing size and mtime, so a rewrite that kept
    the length is caught too.

lib/review.sh had this written out twice — once to hash the ledger, once to
return a record — differing only in the size bound, one extra content rule, and
what they did with the bytes. Duplicated code that exists to be careful is the
kind where one copy quietly stops being careful.
"""

import os
import stat

CHUNK_SIZE = 65536


class PrivateFileError(Exception):
    """The file is not a private record, or changed while being read."""


def read_private_file(path, maximum, require_text_lines=False):
    """Return the file's bytes, or raise PrivateFileError.

    `maximum` is the largest size accepted, in bytes. With
    `require_text_lines`, the content must also end in a newline and contain no
    carriage return — a record written by anything but this code is not one.
    """
    try:
        return _read(path, maximum, require_text_lines)
    except (OSError, ValueError) as error:
        raise PrivateFileError(str(error)) from error


def _read(path, maximum, require_text_lines):
    before = os.lstat(path)
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("not a regular file")
    if before.st_uid != os.geteuid():
        raise ValueError("not owned by this user")
    if stat.S_IMODE(before.st_mode) != 0o600:
        raise ValueError("not mode 0600")
    if not 1 <= before.st_size <= maximum:
        raise ValueError("size out of bounds")

    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError("path changed between check and open")

        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(CHUNK_SIZE, maximum + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > maximum:
                raise ValueError("grew past the size bound while being read")
        content = b"".join(chunks)

        after = os.fstat(descriptor)
        if total != opened.st_size:
            raise ValueError("read a different number of bytes than the file held")
        if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
            opened.st_dev,
            opened.st_ino,
            opened.st_size,
            opened.st_mtime_ns,
        ):
            raise ValueError("changed while being read")
    finally:
        os.close(descriptor)

    if require_text_lines:
        if not content.endswith(b"\n"):
            raise ValueError("does not end in a newline")
        if b"\r" in content:
            raise ValueError("contains a carriage return")
    return content
