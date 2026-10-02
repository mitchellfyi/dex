'use strict';
// Hidden tests for the csv-rfc4180 follow-up task (trim and comment).

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');

function csv() {
  return require(path.join(process.env.BENCH_WS, 'src', 'csv.js'));
}

test('[followup] trim strips spaces and tabs around unquoted fields', () => {
  assert.deepEqual(csv().parse(' a ,\tb\t,  c d  ', { trim: true }), [['a', 'b', 'c d']]);
});

test('[followup] trim allows padding around quotes and keeps quoted content', () => {
  assert.deepEqual(csv().parse('  " a,b " \t, x', { trim: true }), [[' a,b ', 'x']]);
});

test('[followup] without trim, padding before a quote is ordinary text', () => {
  assert.deepEqual(csv().parse(' "a"'), [[' "a"']]);
  assert.throws(() => csv().parse('"a" ,b'), csv().CsvError);
});

test('[followup] trim applies to header names', () => {
  assert.deepEqual(csv().parse(' id , name \n1, Ada ', { header: true, trim: true }), [{ id: '1', name: 'Ada' }]);
});

test('[followup] comment lines are skipped', () => {
  assert.deepEqual(csv().parse('# header note\na,b\n#skip\nc,d\n', { comment: '#' }), [['a', 'b'], ['c', 'd']]);
});

test('[followup] the comment character elsewhere is ordinary', () => {
  assert.deepEqual(csv().parse('a,#b\n"#c",d', { comment: '#' }), [['a', '#b'], ['#c', 'd']]);
  assert.deepEqual(csv().parse(' #x', { comment: '#' }), [[' #x']]);
});

test('[followup] a comment line is not an empty line', () => {
  assert.deepEqual(csv().parse('a\n#c\n\nb', { comment: '#' }), [['a'], [''], ['b']]);
});

test('[followup] error lines still count comment lines', () => {
  assert.throws(() => csv().parse('#1\n#2\na,"b"x', { comment: '#' }), err => err.line === 3 && err.column === 6);
});

test('[followup] comment is validated', () => {
  for (const comment of ['', '##', ',', '"', '\n', 3]) {
    assert.throws(() => csv().parse('a', { comment }), TypeError, JSON.stringify(comment));
  }
});

test('[followup] both options together', () => {
  assert.deepEqual(csv().parse('#; skipped\n; note\n x ; " y " \n', { delimiter: ';', comment: '#', trim: true }), [['', 'note'], ['x', ' y ']]);
});

function streamed(chunks, options) {
  const parser = csv().createParser(options);
  const out = [];
  for (const chunk of chunks) {
    out.push(...parser.write(chunk));
  }
  out.push(...parser.end());
  return out;
}

test('[followup] trim works when padding and quotes are split across writes', () => {
  assert.deepEqual(streamed(['  "a', 'b" ', ' ,', ' c '], { trim: true }), [['ab', 'c']]);
});

test('[followup] a comment line split across writes is skipped', () => {
  assert.deepEqual(streamed(['#no', 'te\r', '\na\n#', 'x'], { comment: '#' }), [['a']]);
});
