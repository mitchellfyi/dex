Build a React component library with the following form components:

**Components:**
1. `TextInput` — text input with label, placeholder, validation, error display
2. `Select` — dropdown select with options, placeholder, required validation
3. `Checkbox` — checkbox with label, controlled/uncontrolled modes
4. `Form` — form wrapper that handles submission, validation, and error state
5. `FormField` — layout wrapper for label + input + error message

**Requirements:**
- Use React 18+ with functional components and hooks
- TypeScript support (JSX/TSX)
- Each component must accept standard HTML attributes via spread props
- Controlled components: value/onChange pattern
- Built-in validation: required, minLength, maxLength, pattern (regex)
- Error messages displayed below the input
- Accessibility: proper aria-* attributes, label associations (htmlFor/id), focus management
- Form handles onSubmit with validation of all fields, prevents default, calls onSubmit only when valid
- Export all components from a single index file

**Tests:**
- Use React Testing Library (@testing-library/react) and Jest
- Test each component renders correctly
- Test validation (required field empty → shows error)
- Test form submission flow (fill → submit → callback called with data)
- Test accessibility (roles, labels, aria attributes)
- Test keyboard navigation (Tab, Enter to submit)
- Include package.json with proper React, testing library, and Jest/Babel config
