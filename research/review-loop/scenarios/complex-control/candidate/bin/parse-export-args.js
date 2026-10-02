'use strict';

const VALID_FORMATS = new Set(['csv', 'json']);

function splitArgument(argument) {
  const separator = argument.indexOf('=');
  return separator === -1
    ? [argument, null]
    : [argument.slice(0, separator), argument.slice(separator + 1)];
}

function parseExportArgs(argv) {
  if (!Array.isArray(argv)) {
    throw new TypeError('arguments must be an array');
  }

  const args = argv.slice();
  const options = { format: 'json', output: null };

  for (let index = 0; index < args.length; index += 1) {
    const [option, inlineValue] = splitArgument(args[index]);
    if (option !== '--format' && option !== '--output') {
      throw new Error(`unknown option: ${option}`);
    }

    const value = inlineValue === null ? args[index + 1] : inlineValue;
    if (inlineValue === null) {
      index += 1;
    }
    if (!value || value.startsWith('--')) {
      throw new Error(`missing value for ${option}`);
    }

    if (option === '--format') {
      if (!VALID_FORMATS.has(value)) {
        throw new Error(`unsupported format: ${value}`);
      }
      options.format = value;
    } else {
      options.output = value;
    }
  }

  return options;
}

module.exports = { parseExportArgs };
