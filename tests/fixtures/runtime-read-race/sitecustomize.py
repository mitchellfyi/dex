# Reproduce an lstat that finishes on the inode a heartbeat just replaced.
import os


_real_lstat = os.lstat
_target = os.environ.get("DX_TEST_RUNTIME_READ_TARGET")
_unlinked_snapshot = None
_returned_snapshot = False


def _lstat_during_replacement(file_name, *args, **kwargs):
    global _unlinked_snapshot, _returned_snapshot
    if file_name != _target:
        return _real_lstat(file_name, *args, **kwargs)

    if _unlinked_snapshot is None:
        descriptor = os.open(file_name, os.O_RDONLY)
        try:
            os.replace(f"{file_name}.next", file_name)
            _unlinked_snapshot = os.fstat(descriptor)
        finally:
            os.close(descriptor)
        if _unlinked_snapshot.st_nlink != 0:
            raise RuntimeError("the replaced record must be unlinked")

    if not _returned_snapshot or os.environ.get("DX_TEST_RUNTIME_READ_RACE") == "always":
        _returned_snapshot = True
        with open(os.environ["DX_TEST_RUNTIME_READ_LOG"], "a", encoding="utf-8") as log:
            log.write("unlinked\n")
        return _unlinked_snapshot
    return _real_lstat(file_name, *args, **kwargs)


if _target:
    os.lstat = _lstat_during_replacement
