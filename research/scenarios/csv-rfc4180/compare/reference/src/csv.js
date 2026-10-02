'use strict';

class CsvError extends Error {
  constructor(message, line, column) {
    super(`${message} at line ${line}, column ${column}`);
    this.name = 'CsvError';
    this.line = line;
    this.column = column;
  }
}

function checkDelimiter(delimiter) {
  if (typeof delimiter !== 'string' || delimiter.length !== 1 || '"\r\n'.includes(delimiter)) {
    throw new TypeError('delimiter must be one character other than ", CR or LF');
  }
}

// A character-at-a-time state machine, so input can arrive in any pieces:
// every decision that depends on the next character (CR then LF, a quote
// then a quote) is kept in state until that character arrives.
class Parser {
  constructor(options = {}) {
    this.delimiter = options.delimiter === undefined ? ',' : options.delimiter;
    checkDelimiter(this.delimiter);
    this.header = options.header === true;
    this.skipEmptyLines = options.skipEmptyLines === true;
    this.names = null;
    this.line = 1;
    this.col = 1;
    this.first = true;
    this.state = 'start'; // start | unquoted | quoted | quote
    this.afterCR = false; // the last break was a CR; an LF next is part of it
    this.quotedCR = false; // inside quotes, the last character was a CR
    this.done = false;
    this.beginRecord();
    this.recordOpen = false; // nothing of the current record seen yet
  }

  beginRecord() {
    this.fields = [];
    this.value = '';
    this.recordLine = this.line;
    this.empty = true;
    this.recordOpen = true;
  }

  startField() {
    this.fieldLine = this.line;
    this.fieldColumn = this.col;
  }

  pushField() {
    this.fields.push({ value: this.value, line: this.fieldLine, column: this.fieldColumn });
    this.value = '';
  }

  finishRecord(out) {
    const record = { fields: this.fields, line: this.recordLine, empty: this.empty };
    this.recordOpen = false;
    if (this.skipEmptyLines && record.empty) {
      return;
    }
    if (!this.header) {
      out.push(record.fields.map(f => f.value));
      return;
    }
    if (!this.names) {
      const seen = new Set();
      for (const field of record.fields) {
        if (seen.has(field.value)) {
          throw new CsvError(`duplicate header ${JSON.stringify(field.value)}`, field.line, field.column);
        }
        seen.add(field.value);
      }
      this.names = record.fields.map(f => f.value);
      return;
    }
    if (record.fields.length !== this.names.length) {
      throw new CsvError(`expected ${this.names.length} fields, found ${record.fields.length}`, record.line, 1);
    }
    out.push(Object.fromEntries(this.names.map((name, k) => [name, record.fields[k].value])));
  }

  lineBreak(ch) {
    this.line += 1;
    this.col = 1;
    this.afterCR = ch === '\r';
  }

  step(ch, out) {
    if (this.afterCR) {
      this.afterCR = false;
      if (ch === '\n') {
        return;
      }
    }
    if (!this.recordOpen) {
      this.beginRecord();
    }
    const d = this.delimiter;
    switch (this.state) {
      case 'start':
        this.startField();
        if (ch === '"') {
          this.empty = false;
          this.quoteLine = this.line;
          this.quoteColumn = this.col;
          this.state = 'quoted';
          this.col += 1;
        } else if (ch === d) {
          this.empty = false;
          this.pushField();
          this.col += 1;
        } else if (ch === '\r' || ch === '\n') {
          this.pushField();
          this.finishRecord(out);
          this.lineBreak(ch);
        } else {
          this.empty = false;
          this.value = ch;
          this.state = 'unquoted';
          this.col += 1;
        }
        return;
      case 'unquoted':
        if (ch === d) {
          this.pushField();
          this.state = 'start';
          this.col += 1;
        } else if (ch === '\r' || ch === '\n') {
          this.pushField();
          this.finishRecord(out);
          this.state = 'start';
          this.lineBreak(ch);
        } else {
          this.value += ch;
          this.col += 1;
        }
        return;
      case 'quoted':
        if (ch === '"') {
          this.quotedCR = false;
          this.state = 'quote';
          this.col += 1;
          return;
        }
        this.value += ch;
        if (ch === '\n' && this.quotedCR) {
          this.quotedCR = false;
        } else if (ch === '\r' || ch === '\n') {
          this.line += 1;
          this.col = 1;
          this.quotedCR = ch === '\r';
        } else {
          this.quotedCR = false;
          this.col += 1;
        }
        return;
      case 'quote':
        if (ch === '"') {
          this.value += '"';
          this.state = 'quoted';
          this.col += 1;
        } else if (ch === d) {
          this.pushField();
          this.state = 'start';
          this.col += 1;
        } else if (ch === '\r' || ch === '\n') {
          this.pushField();
          this.finishRecord(out);
          this.state = 'start';
          this.lineBreak(ch);
        } else {
          throw new CsvError(`unexpected ${JSON.stringify(ch)} after a closing quote`, this.line, this.col);
        }
        return;
      default:
        throw new Error(`unknown state ${this.state}`);
    }
  }

  guard() {
    if (this.done) {
      throw new Error('the parser has finished');
    }
  }

  write(chunk) {
    this.guard();
    if (typeof chunk !== 'string') {
      throw new TypeError('chunk must be a string');
    }
    const out = [];
    try {
      for (let i = 0; i < chunk.length; i++) {
        if (this.first) {
          this.first = false;
          if (chunk.charCodeAt(i) === 0xfeff) {
            continue;
          }
        }
        this.step(chunk[i], out);
      }
    } catch (err) {
      this.done = true;
      throw err;
    }
    return out;
  }

  end() {
    this.guard();
    this.done = true;
    const out = [];
    if (this.state === 'quoted') {
      throw new CsvError('unterminated quoted field', this.quoteLine, this.quoteColumn);
    }
    if (this.state === 'unquoted' || this.state === 'quote') {
      this.pushField();
      this.finishRecord(out);
    } else if (this.recordOpen && this.fields.length > 0) {
      // Input ended right after a delimiter: the last field is empty.
      this.startField();
      this.pushField();
      this.finishRecord(out);
    }
    return out;
  }
}

function createParser(options = {}) {
  const parser = new Parser(options);
  return { write: chunk => parser.write(chunk), end: () => parser.end() };
}

function parse(text, options = {}) {
  if (typeof text !== 'string') {
    throw new TypeError('text must be a string');
  }
  const parser = new Parser(options);
  return [...parser.write(text), ...parser.end()];
}

function stringify(rows, options = {}) {
  const delimiter = options.delimiter === undefined ? ',' : options.delimiter;
  checkDelimiter(delimiter);
  const eol = options.eol === undefined ? '\r\n' : options.eol;
  if (eol !== '\r\n' && eol !== '\n') {
    throw new TypeError("eol must be '\\r\\n' or '\\n'");
  }
  if (!Array.isArray(rows)) {
    throw new TypeError('rows must be an array');
  }
  const header = options.header;
  if (header !== undefined && !Array.isArray(header)) {
    throw new TypeError('header must be an array of column names');
  }

  function cell(value) {
    if (value === null || value === undefined) {
      return '';
    }
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return String(value);
    }
    throw new TypeError(`cannot write a ${typeof value} value`);
  }

  function quote(text) {
    const needs = text.includes(delimiter) || /["\r\n]/.test(text) || text.startsWith(' ') || text.endsWith(' ');
    return needs ? `"${text.replace(/"/g, '""')}"` : text;
  }

  function record(values) {
    const cells = values.map(cell);
    if (cells.length === 1 && cells[0] === '') {
      return '""';
    }
    return cells.map(quote).join(delimiter);
  }

  const lines = header ? [record(header)] : [];
  for (const row of rows) {
    if (Array.isArray(row)) {
      lines.push(record(row));
    } else if (header && row && typeof row === 'object') {
      lines.push(record(header.map(name => row[name])));
    } else {
      throw new TypeError('each row must be an array, or an object when header is given');
    }
  }
  return lines.length ? lines.join(eol) + eol : '';
}

module.exports = { parse, stringify, createParser, CsvError };
