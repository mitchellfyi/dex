'use strict';

function parseExportArgs(argv) {
  const options = { format: 'json', output: null };

  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--format') {
      options.format = argv[index + 1];
      index += 1;
    } else if (argument === '--output') {
      options.output = argv[index + 1];
      index += 1;
    } else {
      throw new Error(`unknown option: ${argument}`);
    }
  }

  return options;
}

module.exports = { parseExportArgs };
