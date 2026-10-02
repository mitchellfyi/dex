Build a Go package called `strutil` that provides the following string utility functions:

1. **Reverse(s string) string** — reverses a string (must handle Unicode correctly)
2. **Capitalize(s string) string** — capitalizes the first letter of each word
3. **Truncate(s string, maxLen int) string** — truncates to maxLen, adding "..." if truncated
4. **Slugify(s string) string** — converts to lowercase, replaces spaces/special chars with hyphens, strips leading/trailing hyphens

Initialize a Go module with `go mod init strutil`.
