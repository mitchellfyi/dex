const { Validator, logger } = require('../lib/v3');

function validateSignup(input) {
  const validator = new Validator();
  const missing = validator.requireFields(input, ['name', 'email']);
  const errors = [];

  for (const field of missing) {
    errors.push(`${field} is required`);
  }
  if (input.email && !validator.checkEmail(input.email)) {
    errors.push('email is invalid');
  }

  if (errors.length > 0) {
    logger.warn('signup validation failed', { errors });
  }

  return {
    valid: errors.length === 0,
    errors
  };
}

module.exports = { validateSignup };
