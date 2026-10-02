# Export argument parser

`parseExportArgs(argv)` parses the public export command's `--format` and
`--output` options. It accepts both separate and `--name=value` forms, rejects
unknown or empty values, and must not mutate the caller's argument array.

Run the visible checks with:

```sh
node --test tests/visible.test.js
```
