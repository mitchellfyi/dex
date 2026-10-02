const crypto = require('node:crypto');

const DEFAULT_ALLOWED_PROTOCOLS = ['http:', 'https:'];
const DEFAULT_REDIRECT_KEYS = ['next', 'return_to', 'redirect_uri'];

function buildUrl(options) {
  const normalized = normalizeOptions(options);
  const base = normalizeBaseUrl(normalized.baseUrl, normalized.allowedProtocols);
  const path = normalizePath(normalized.path);
  const query = serializeQuery(normalized.query);

  const url = new URL(base);
  url.pathname = joinPaths(url.pathname, path);
  if (query) {
    url.search = query;
  }

  return url.toString();
}

function buildSignedUrl(options, signingKey) {
  if (!signingKey || typeof signingKey !== 'string') {
    throw new TypeError('signingKey must be a non-empty string');
  }

  const unsigned = buildUrl(options);
  const signature = crypto
    .createHmac('sha256', signingKey)
    .update(unsigned)
    .digest('hex');

  const separator = unsigned.includes('?') ? '&' : '?';
  return `${unsigned}${separator}signature=${signature}`;
}

function redactUrl(rawUrl, keys = DEFAULT_REDIRECT_KEYS) {
  const url = new URL(rawUrl);
  for (const key of keys) {
    if (url.searchParams.has(key)) {
      url.searchParams.set(key, '[redacted]');
    }
  }
  return url.toString();
}

function normalizeOptions(options) {
  if (!options || typeof options !== 'object') {
    throw new TypeError('options object is required');
  }
  if (!options.baseUrl) {
    throw new TypeError('baseUrl is required');
  }

  return {
    baseUrl: options.baseUrl,
    path: options.path || [],
    query: options.query || {},
    allowedProtocols: options.allowedProtocols || DEFAULT_ALLOWED_PROTOCOLS
  };
}

function normalizeBaseUrl(baseUrl, allowedProtocols) {
  const url = new URL(baseUrl);
  if (!allowedProtocols.includes(url.protocol)) {
    throw new TypeError(`unsupported protocol: ${url.protocol}`);
  }
  url.hash = '';
  return url.toString();
}

function normalizePath(path) {
  const segments = Array.isArray(path) ? path : String(path).split('/');
  return segments
    .filter(segment => segment !== undefined && segment !== null)
    .map(segment => encodePathSegment(String(segment)))
    .filter(Boolean)
    .join('/');
}

function encodePathSegment(segment) {
  const trimmed = segment.trim();
  if (!trimmed || trimmed === '/') {
    return '';
  }
  return trimmed
    .split('/')
    .filter(Boolean)
    .map(part => encodeURIComponent(decodeIfSafe(part)))
    .join('/');
}

function decodeIfSafe(value) {
  try {
    return decodeURIComponent(value);
  } catch (_err) {
    return value;
  }
}

function joinPaths(basePath, extraPath) {
  const left = basePath.replace(/\/+$/, '');
  const right = extraPath.replace(/^\/+/, '');
  if (!left && !right) {
    return '/';
  }
  if (!left) {
    return `/${right}`;
  }
  if (!right) {
    return left || '/';
  }
  return `${left}/${right}`;
}

function serializeQuery(query) {
  if (query instanceof URLSearchParams) {
    return query.toString();
  }
  if (!query || typeof query !== 'object') {
    return '';
  }

  const params = new URLSearchParams();
  for (const key of Object.keys(query).sort()) {
    const value = query[key];
    if (!value) {
      continue;
    }
    appendQueryValue(params, key, value);
  }
  return params.toString();
}

function appendQueryValue(params, key, value) {
  if (Array.isArray(value)) {
    for (const item of value) {
      if (!item) {
        continue;
      }
      params.append(key, formatQueryValue(item));
    }
    return;
  }

  params.append(key, formatQueryValue(value));
}

function formatQueryValue(value) {
  if (value instanceof Date) {
    return value.toISOString();
  }
  if (typeof value === 'object') {
    return JSON.stringify(value);
  }
  return String(value);
}

function parseRetryAfter(headerValue, now = new Date()) {
  if (!headerValue) {
    return null;
  }

  const asSeconds = Number(headerValue);
  if (Number.isFinite(asSeconds)) {
    return new Date(now.getTime() + asSeconds * 1000);
  }

  const asDate = new Date(headerValue);
  if (!Number.isNaN(asDate.getTime())) {
    return asDate;
  }

  return null;
}

function isSafeRedirect(rawUrl, allowedHosts) {
  if (!rawUrl) {
    return false;
  }

  let url;
  try {
    url = new URL(rawUrl);
  } catch (_err) {
    return false;
  }

  if (!DEFAULT_ALLOWED_PROTOCOLS.includes(url.protocol)) {
    return false;
  }
  return allowedHosts.includes(url.host);
}

module.exports = {
  buildUrl,
  buildSignedUrl,
  redactUrl,
  parseRetryAfter,
  isSafeRedirect,
  _private: {
    serializeQuery,
    normalizePath,
    joinPaths
  }
};
