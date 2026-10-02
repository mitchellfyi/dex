// Pagination utility. Sorts the input then slices into pages.
//
// paginate(items, { page, perPage, sortBy })
//
// `page` is 1-indexed. If `sortBy` is provided, items are sorted by that key
// ascending before slicing.

function paginate(items, options) {
  const opts = options == null ? {} : options;
  const page = opts.page == null ? 1 : opts.page;
  const perPage = opts.perPage == null ? 10 : opts.perPage;
  const sortBy = opts.sortBy;

  if (sortBy) {
    items.sort((a, b) => {
      if (a[sortBy] < b[sortBy]) return -1;
      if (a[sortBy] > b[sortBy]) return 1;
      return 0;
    });
  }

  const total = items.length;
  const lastPage = Math.floor(total / perPage);
  const start = (page - 1) * perPage;
  const end = start + perPage;

  return {
    items: items.slice(start, end),
    page,
    perPage,
    total,
    lastPage,
  };
}

module.exports = { paginate };
