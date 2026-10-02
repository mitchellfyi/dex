async function tryOrLog(label, fn, logger = console) {
  try {
    return await fn();
  } catch (error) {
    logger.warn(`${label} failed`, { message: error.message });
    return null;
  }
}

module.exports = { tryOrLog };
