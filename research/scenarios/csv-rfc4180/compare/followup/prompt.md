Add two options to `parse` and `createParser` in `src/csv.js`. Both are off by default, and without them nothing changes. As with every other option, `createParser` must give the same result as `parse` wherever the input is split.

- `trim: true` removes spaces and tabs from both ends of every unquoted field. Spaces and tabs are also allowed before a field's opening `"` and after its closing `"`; they are removed, and the content between the quotes is kept exactly. A field with spaces before its opening quote is still a quoted field.
- `comment` is a single character. A line whose first character is the comment character is skipped entirely, with its line break; it is not an empty line and never becomes a record. The comment character anywhere else is ordinary. `comment` must be one character other than the delimiter, `"`, CR and LF; anything else throws `TypeError`. Line numbers in errors still count comment lines.

Keep the existing behaviour and tests working, and add tests for both options.
