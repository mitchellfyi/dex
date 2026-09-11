#!/usr/bin/env python3
"""Private Keychain and advisory-lock operations for the optional CCR runtime."""

import ctypes
import fcntl
import json
import os
import re
import stat
import sys


def keychain(operation, service, account, value=None):
    if not (service == "Dex CCR OAuth" or re.fullmatch(r"Claude Code-credentials-[0-9a-f]{8}", service)):
        raise ValueError("Invalid credential service")
    security = ctypes.CDLL("/System/Library/Frameworks/Security.framework/Security")
    core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    pointer = ctypes.c_void_p
    number = ctypes.c_uint32
    find = security.SecKeychainFindGenericPassword
    find.argtypes = [pointer, number, ctypes.c_char_p, number, ctypes.c_char_p,
                     ctypes.POINTER(number), ctypes.POINTER(pointer), ctypes.POINTER(pointer)]
    find.restype = ctypes.c_int32
    free = security.SecKeychainItemFreeContent
    free.argtypes = [pointer, pointer]
    core.CFRelease.argtypes = [pointer]
    service_bytes, account_bytes = service.encode(), account.encode()
    size, data, item = number(), pointer(), pointer()
    result = find(None, len(service_bytes), service_bytes, len(account_bytes), account_bytes,
                  ctypes.byref(size), ctypes.byref(data), ctypes.byref(item))
    if result not in (0, -25300):
        raise RuntimeError(f"Keychain access failed ({result})")
    try:
        if operation == "read":
            return json.loads(ctypes.string_at(data, size.value)) if result == 0 else None
        if operation == "delete":
            if result == 0:
                security.SecKeychainItemDelete.argtypes = [pointer]
                result = security.SecKeychainItemDelete(item)
            else:
                result = 0
        elif operation == "write":
            encoded = json.dumps(value).encode()
            if result == 0:
                change = security.SecKeychainItemModifyAttributesAndData
                change.argtypes = [pointer, pointer, number, ctypes.c_char_p]
                result = change(item, None, len(encoded), encoded)
            else:
                add = security.SecKeychainAddGenericPassword
                add.argtypes = [pointer, number, ctypes.c_char_p, number, ctypes.c_char_p,
                                number, ctypes.c_char_p, ctypes.POINTER(pointer)]
                result = add(None, len(service_bytes), service_bytes, len(account_bytes), account_bytes,
                             len(encoded), encoded, None)
        else:
            raise ValueError("Invalid credential operation")
        if result:
            raise RuntimeError(f"Keychain operation failed ({result})")
        return None
    finally:
        if data:
            free(None, data)
        if item:
            core.CFRelease(item)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "lock":
        fd = os.open(sys.argv[2], os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ValueError("Unsafe lock file")
        with os.fdopen(fd, "w") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            print("locked", flush=True)
            sys.stdin.read()
        return
    request = json.load(sys.stdin)
    print(json.dumps(keychain(request["operation"], request["service"], request["account"], request.get("value"))))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Credential storage operation failed: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
