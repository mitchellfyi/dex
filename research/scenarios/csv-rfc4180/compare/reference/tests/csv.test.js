const test = require('node:test');
const assert = require('node:assert/strict');
const { parse, stringify, CsvError } = require('../src/csv');

test('parses quoted fields, escaped quotes and embedded breaks', () => {
  assert.deepEqual(parse('a,"b,c","d""e"\r\n"x\ny",z\n'), [['a', 'b,c', 'd"e'], ['x\ny', 'z']]);
});

test('reports unterminated quotes with their position', () => {
  assert.throws(() => parse('a\n"b,c'), err => err instanceof CsvError && err.line === 2 && err.column === 1);
});

test('header mode builds objects and checks field counts', () => {
  assert.deepEqual(parse('a,b\n1,2\n', { header: true }), [{ a: '1', b: '2' }]);
  assert.throws(() => parse('a,b\n1\n', { header: true }), CsvError);
});

test('stringify quotes only when needed and round-trips', () => {
  const rows = [['plain', 'a,b', 'say "hi"', ' pad'], ['']];
  const text = stringify(rows);
  assert.equal(text, 'plain,"a,b","say ""hi"""," pad"\r\n""\r\n');
  assert.deepEqual(parse(text), rows);
});
