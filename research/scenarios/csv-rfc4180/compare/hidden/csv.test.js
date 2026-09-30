'use strict';
// Hidden tests for csv-rfc4180. The agent never sees these.
//
// [spec]   a sentence of prompt.md, checked directly
// [robust] two or more of its rules combined, or at the edges they meet

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

function csv() {
  return require(path.join(process.env.BENCH_WS, 'src', 'csv.js'));
}

function csvError(line, column) {
  return err => {
    assert.ok(err instanceof csv().CsvError, `expected CsvError, got ${err && err.name}: ${err && err.message}`);
    assert.ok(err instanceof Error);
    assert.equal(err.line, line, 'line');
    assert.equal(err.column, column, 'column');
    return true;
  };
}

// ── parse ────────────────────────────────────────────────────────────────────

test('[spec] parses plain records', () => {
  assert.deepEqual(csv().parse('a,b,c\n1,2,3'), [['a', 'b', 'c'], ['1', '2', '3']]);
});

test('[spec] empty input returns no records, and non-strings are rejected', () => {
  assert.deepEqual(csv().parse(''), []);
  for (const bad of [null, undefined, 42, ['a']]) {
    assert.throws(() => csv().parse(bad), TypeError);
  }
});

test('[spec] CRLF, LF and CR all end records, mixed in one input', () => {
  assert.deepEqual(csv().parse('a\r\nb\nc\rd'), [['a'], ['b'], ['c'], ['d']]);
});

test('[spec] a leading BOM is ignored', () => {
  assert.deepEqual(csv().parse('﻿name,age\nAda,36'), [['name', 'age'], ['Ada', '36']]);
});

test('[spec] quoted fields keep delimiters, line breaks and doubled quotes', () => {
  assert.deepEqual(csv().parse('"a,b","line1\r\nline2","say ""hi"""'), [['a,b', 'line1\r\nline2', 'say "hi"']]);
});

test('[spec] a quote inside an unquoted field is an ordinary character', () => {
  assert.deepEqual(csv().parse('5" pipe,ab"c"'), [['5" pipe', 'ab"c"']]);
});

test('[spec] whitespace is never trimmed', () => {
  assert.deepEqual(csv().parse(' a , b ,\t'), [[' a ', ' b ', '\t']]);
});

test('[spec] one trailing line break does not add a record', () => {
  assert.deepEqual(csv().parse('a,b\n'), [['a', 'b']]);
  assert.deepEqual(csv().parse('a,b\r\n'), [['a', 'b']]);
});

test('[spec] other empty lines are records with one empty field', () => {
  assert.deepEqual(csv().parse('a\n\nb\n\n'), [['a'], [''], ['b'], ['']]);
});

test('[spec] skipEmptyLines drops empty lines', () => {
  assert.deepEqual(csv().parse('a\n\nb\n\n', { skipEmptyLines: true }), [['a'], ['b']]);
});

test('[spec] a custom delimiter is used and validated', () => {
  assert.deepEqual(csv().parse('a;b,c;"d;e"', { delimiter: ';' }), [['a', 'b,c', 'd;e']]);
  assert.deepEqual(csv().parse('a\tb', { delimiter: '\t' }), [['a', 'b']]);
  for (const delimiter of ['', ';;', '"', '\n', '\r', 5]) {
    assert.throws(() => csv().parse('a', { delimiter }), TypeError, JSON.stringify(delimiter));
  }
});

test('[spec] header mode returns objects keyed by the first record', () => {
  assert.deepEqual(csv().parse('name,age\nAda,36\nAlan,41\n', { header: true }), [
    { name: 'Ada', age: '36' },
    { name: 'Alan', age: '41' }
  ]);
  assert.deepEqual(csv().parse('name,age\n', { header: true }), []);
  assert.deepEqual(csv().parse('', { header: true }), []);
});

test('[spec] an unterminated quoted field reports where the quote opened', () => {
  assert.throws(() => csv().parse('a,b\nc,"never closed'), csvError(2, 3));
});

test('[spec] a character after a closing quote reports its own position', () => {
  assert.throws(() => csv().parse('a,"b"x,c'), csvError(1, 6));
});

test('[spec] a duplicate header name reports its second field', () => {
  assert.throws(() => csv().parse('id,name,id\n1,2,3', { header: true }), csvError(1, 9));
});

test('[spec] a record with the wrong field count reports its line', () => {
  assert.throws(() => csv().parse('a,b\n1,2\n3\n', { header: true }), csvError(3, 1));
  assert.throws(() => csv().parse('a,b\n1,2,3\n', { header: true }), csvError(2, 1));
});

// ── stringify ────────────────────────────────────────────────────────────────

test('[spec] stringify writes records joined by CRLF with a final CRLF', () => {
  assert.equal(csv().stringify([['a', 'b'], ['c', 'd']]), 'a,b\r\nc,d\r\n');
  assert.equal(csv().stringify([]), '');
});

test('[spec] stringify quotes exactly the fields that need it', () => {
  const out = csv().stringify([['plain', 'a,b', 'say "hi"', 'x\ny', 'x\ry', ' lead', 'trail ', '\ttab', 'mid dle']]);
  assert.equal(out, 'plain,"a,b","say ""hi""","x\ny","x\ry"," lead","trail ",\ttab,mid dle\r\n');
});

test('[spec] stringify converts numbers, booleans and empty values', () => {
  assert.equal(csv().stringify([[1, 2.5, -0, true, false, null, undefined, '']]), '1,2.5,0,true,false,,,\r\n');
});

test('[spec] stringify rejects other value types', () => {
  for (const value of [{}, [1], new Date(0), () => 1, Symbol('s')]) {
    assert.throws(() => csv().stringify([[value]]), TypeError);
  }
});

test('[spec] a record of one empty field is written as ""', () => {
  assert.equal(csv().stringify([['a'], [''], ['b']]), 'a\r\n""\r\nb\r\n');
});

test('[spec] eol and delimiter options', () => {
  assert.equal(csv().stringify([['a', 'b;c'], ['d', 'e']], { eol: '\n', delimiter: ';' }), 'a;"b;c"\nd;e\n');
  assert.throws(() => csv().stringify([['a']], { eol: '\r' }), TypeError);
  assert.throws(() => csv().stringify([['a']], { delimiter: '"' }), TypeError);
});

test('[spec] header option writes objects in header order', () => {
  const out = csv().stringify([{ b: 2, a: 1 }, { a: 'x' }, ['p', 'q']], { header: ['a', 'b'] });
  assert.equal(out, 'a,b\r\n1,2\r\nx,\r\np,q\r\n');
});

// ── Combinations ─────────────────────────────────────────────────────────────

const TRICKY = [
  ['a', '', 'b'],
  [''],
  ['"'],
  ['""'],
  [' '],
  ['a\r\nb', 'c\rd', 'e\nf'],
  ['x,y', ',', ',,'],
  ['ü', '日本', '😀 emoji'],
  ['', ''],
  ['trailing space ', ' leading space']
];

test('[robust] tricky rows survive a round trip, with and without skipEmptyLines', () => {
  for (const options of [{}, { skipEmptyLines: true }, { eol: '\n' }, { delimiter: ';' }, { delimiter: '\t', eol: '\n' }]) {
    const text = csv().stringify(TRICKY, options);
    assert.deepEqual(csv().parse(text, options), TRICKY, JSON.stringify(options));
  }
});

test('[robust] a lone line break is one empty record', () => {
  assert.deepEqual(csv().parse('\n'), [['']]);
  assert.deepEqual(csv().parse('\r\n', { skipEmptyLines: true }), []);
});

test('[robust] LF then CR is two line breaks, not one', () => {
  assert.deepEqual(csv().parse('a\n\rb'), [['a'], [''], ['b']]);
});

test('[robust] positions count lines inside quoted fields', () => {
  assert.throws(() => csv().parse('"a\r\nb\nc"x'), csvError(3, 3));
  assert.throws(() => csv().parse('ok\r\n\r\n"a\rb"!'), csvError(4, 3));
});

test('[robust] error positions ignore the BOM', () => {
  assert.throws(() => csv().parse('﻿"a"b'), csvError(1, 4));
});

test('[robust] header positions account for skipped empty lines', () => {
  assert.throws(() => csv().parse('\n\nx,x\n1,2', { header: true, skipEmptyLines: true }), csvError(3, 3));
});

test('[robust] a record spanning lines reports the line it starts on', () => {
  assert.throws(() => csv().parse('a,b\n"multi\nline"\n', { header: true }), csvError(2, 1));
});

test('[robust] header names such as __proto__ become ordinary keys', () => {
  const [row] = csv().parse('__proto__,constructor\n1,2', { header: true });
  assert.equal(Object.getPrototypeOf(row), Object.prototype);
  assert.deepEqual(Object.keys(row), ['__proto__', 'constructor']);
  assert.equal(row.__proto__, '1');
});

test('[robust] an empty quoted field is not an empty line', () => {
  assert.deepEqual(csv().parse('""\n', { skipEmptyLines: true }), [['']]);
});

test('[robust] quoted field at end of input without a break', () => {
  assert.deepEqual(csv().parse('a,"b"'), [['a', 'b']]);
  assert.deepEqual(csv().parse('a,'), [['a', '']]);
});

// ── createParser ─────────────────────────────────────────────────────────────

function streamed(chunks, options) {
  const parser = csv().createParser(options);
  const out = [];
  for (const chunk of chunks) {
    out.push(...parser.write(chunk));
  }
  out.push(...parser.end());
  return out;
}

// Every way to cut text into pieces of at most `size` characters, starting
// the cuts at each offset.
function chunkings(text, size) {
  const out = [];
  for (let offset = 0; offset < size; offset++) {
    const chunks = [text.slice(0, offset)];
    for (let i = offset; i < text.length; i += size) {
      chunks.push(text.slice(i, i + size));
    }
    out.push(chunks);
  }
  out.push([...text]);
  return out;
}

test('[spec] a record is returned by the write that completes it', () => {
  const parser = csv().createParser();
  assert.deepEqual(parser.write('a,b\n1,'), [['a', 'b']]);
  assert.deepEqual(parser.write('2\n3'), [['1', '2']]);
  assert.deepEqual(parser.end(), [['3']]);
});

test('[spec] CRLF split across writes is one line break', () => {
  assert.deepEqual(streamed(['a\r', '\nb\r', '\n']), [['a'], ['b']]);
});

test('[spec] an escaped quote split across writes', () => {
  assert.deepEqual(streamed(['"a"', '"b"\n']), [['a"b']]);
  assert.deepEqual(streamed(['"a""', 'b"']), [['a"b']]);
});

test('[spec] a quoted line break split across writes', () => {
  assert.deepEqual(streamed(['"x\r', '\ny",z']), [['x\r\ny', 'z']]);
});

test('[spec] a BOM in the first chunk is ignored', () => {
  assert.deepEqual(streamed(['﻿a,', 'b']), [['a', 'b']]);
});

test('[spec] errors keep their positions across writes', () => {
  assert.throws(() => streamed(['a,"b', '"x']), csvError(1, 6));
  assert.throws(() => streamed(['ok\n', '"never']), csvError(2, 1));
});

test('[spec] header mode streams objects', () => {
  assert.deepEqual(streamed(['id,na', 'me\n1,', 'Ada\n2,Alan'], { header: true }), [
    { id: '1', name: 'Ada' },
    { id: '2', name: 'Alan' }
  ]);
});

test('[spec] the parser finishes after end() and after an error', () => {
  const parser = csv().createParser();
  parser.write('a');
  parser.end();
  assert.throws(() => parser.write('b'), Error);
  assert.throws(() => parser.end(), Error);
  const failed = csv().createParser();
  assert.throws(() => failed.write('"a"x'), csv().CsvError);
  assert.throws(() => failed.write('b'), Error);
  assert.throws(() => csv().createParser().write(42), TypeError);
});

test('[spec] the first error in the input wins', () => {
  assert.throws(() => csv().parse('a,b\n1\n"open', { header: true }), csvError(2, 1));
  assert.throws(() => csv().parse('"a"x\n"open'), csvError(1, 4));
});

test('[robust] every chunking of tricky input gives the same records', () => {
  const text = '﻿"a""b",c\r\n\r\n"x\r\ny",""\n ,\t\r"",\n";"\n';
  const whole = csv().parse(text);
  for (const size of [1, 2, 3, 5]) {
    for (const chunks of chunkings(text, size)) {
      assert.deepEqual(streamed(chunks), whole, JSON.stringify(chunks));
    }
  }
});

test('[robust] chunked header mode with skipped empty lines', () => {
  const text = '\r\nid,v\r\n\r\n1,"a\r\nb"\r\n2,c\r\n';
  const options = { header: true, skipEmptyLines: true };
  const whole = csv().parse(text, options);
  assert.deepEqual(whole, [{ id: '1', v: 'a\r\nb' }, { id: '2', v: 'c' }]);
  for (const chunks of chunkings(text, 2)) {
    assert.deepEqual(streamed(chunks, options), whole, JSON.stringify(chunks));
  }
});

test('[robust] empty writes change nothing', () => {
  assert.deepEqual(streamed(['', 'a', '', '\n', '', 'b', '']), [['a'], ['b']]);
});
