'use strict';

const { test, mock, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const path = require('path');
require('./helpers');
const { Store } = require('../src/main/store');

afterEach(() => {
  mock.restoreAll();
});

function freshStore() {
  const store = new Store();
  fs.rmSync(store.file, { force: true });
  store.data = JSON.parse(JSON.stringify(store.data));
  return store;
}

test('saveToken reports failure and keeps the previous credential when the write fails', () => {
  const store = freshStore();
  assert.equal(store.saveToken('first-token'), true);
  mock.method(fs, 'writeFileSync', () => {
    throw new Error('ENOSPC');
  });
  assert.equal(store.saveToken('second-token'), false);
  assert.equal(store.getToken(), 'first-token');
});

test('deleteToken falls back to removing the file when it cannot be rewritten', () => {
  const store = freshStore();
  store.saveToken('secret-token');
  mock.method(fs, 'writeFileSync', () => {
    throw new Error('EROFS');
  });
  assert.equal(store.deleteToken(), true);
  assert.equal(fs.existsSync(store.file), false);
});

test('deleteToken reports failure when the token is still on disk', () => {
  const store = freshStore();
  store.saveToken('secret-token');
  mock.method(fs, 'writeFileSync', () => {
    throw new Error('EROFS');
  });
  mock.method(fs, 'rmSync', () => {
    throw new Error('EPERM');
  });
  assert.equal(store.deleteToken(), false);
  assert.ok(fs.readFileSync(store.file, 'utf8').includes('"token"'));
});

test('ordinary settings failures are surfaced through onSaveError', () => {
  const store = freshStore();
  const errors = [];
  store.onSaveError = (error) => errors.push(error.message);
  mock.method(fs, 'writeFileSync', () => {
    throw new Error('EACCES');
  });
  store.setPollInterval(30);
  assert.deepEqual(errors, ['EACCES']);
  assert.ok(path.isAbsolute(store.file));
});
