# Hook lock ownership

`releaseLock(lockPath, ownerToken)` removes a hook lock only when the stored
owner token matches the caller. A non-owner must receive `false`, and the lock
must remain intact. Symlink lock paths must also be left untouched.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
