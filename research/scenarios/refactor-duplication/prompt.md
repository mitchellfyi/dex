The following code has three nearly-identical validation functions. Create these files, then refactor to eliminate the duplication while preserving all behavior. Write tests proving behavior is preserved.

Create `src/routes/users.js`:
```javascript
function validateUserInput(data) {
  const errors = [];
  if (!data.name || typeof data.name !== 'string') {
    errors.push('name is required and must be a string');
  }
  if (data.name && data.name.length > 100) {
    errors.push('name must be 100 characters or less');
  }
  if (!data.email || typeof data.email !== 'string') {
    errors.push('email is required and must be a string');
  }
  if (data.email && !data.email.includes('@')) {
    errors.push('email must be a valid email address');
  }
  if (data.age !== undefined && (typeof data.age !== 'number' || data.age < 0 || data.age > 150)) {
    errors.push('age must be a number between 0 and 150');
  }
  return { valid: errors.length === 0, errors };
}

module.exports = { validateUserInput };
```

Create `src/routes/products.js`:
```javascript
function validateProductInput(data) {
  const errors = [];
  if (!data.name || typeof data.name !== 'string') {
    errors.push('name is required and must be a string');
  }
  if (data.name && data.name.length > 100) {
    errors.push('name must be 100 characters or less');
  }
  if (!data.sku || typeof data.sku !== 'string') {
    errors.push('sku is required and must be a string');
  }
  if (data.price !== undefined && (typeof data.price !== 'number' || data.price < 0)) {
    errors.push('price must be a non-negative number');
  }
  if (data.description && data.description.length > 500) {
    errors.push('description must be 500 characters or less');
  }
  return { valid: errors.length === 0, errors };
}

module.exports = { validateProductInput };
```

Create `src/routes/orders.js`:
```javascript
function validateOrderInput(data) {
  const errors = [];
  if (!data.customerId || typeof data.customerId !== 'string') {
    errors.push('customerId is required and must be a string');
  }
  if (!data.items || !Array.isArray(data.items) || data.items.length === 0) {
    errors.push('items is required and must be a non-empty array');
  }
  if (data.notes && data.notes.length > 500) {
    errors.push('notes must be 500 characters or less');
  }
  if (data.total !== undefined && (typeof data.total !== 'number' || data.total < 0)) {
    errors.push('total must be a non-negative number');
  }
  return { valid: errors.length === 0, errors };
}

module.exports = { validateOrderInput };
```

Also create a `package.json` with a test script.

Refactoring requirements:
- Extract common validation patterns (required string, max length, numeric range) into a shared validator utility
- Each route file should use the shared utility instead of duplicated inline checks
- All original validation behavior must be preserved exactly
- Include tests that verify each route's validation still works correctly after refactoring
