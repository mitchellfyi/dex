function toDate(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new TypeError('valid date is required');
  }
  return date;
}

function formatIsoDate(value) {
  const date = toDate(value);
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth() + 1;
  const day = date.getUTCDate();
  return `${year}-${month}-${day}`;
}

function formatDateRange(start, end) {
  const startDate = toDate(start);
  const endDate = toDate(end);
  if (startDate.getTime() > endDate.getTime()) {
    throw new RangeError('start must be before or equal to end');
  }
  return `${formatIsoDate(startDate)} to ${formatIsoDate(endDate)}`;
}

module.exports = {
  formatIsoDate,
  formatDateRange
};
