Build a Python data validation library with the following validators:

1. **Email validator**: Validates email addresses (handle common formats, reject obvious invalids)
2. **URL validator**: Validates URLs (must have scheme, handle edge cases)
3. **Phone number validator**: Validates US phone numbers (10 digits, with/without formatting)
4. **Credit card validator**: Validates credit card numbers using the Luhn algorithm
5. **Date range validator**: Validates that a start date is before an end date, both are valid dates

Each validator function should:
- Accept a string input
- Return a tuple: `(is_valid: bool, error_message: str)` where error_message is empty string on success
- Handle None/empty string input gracefully

Structure:
- `validators/` package with one module per validator
- `validators/__init__.py` that exports all validators
- Comprehensive tests in `tests/` directory using pytest
- No external dependencies — stdlib only
