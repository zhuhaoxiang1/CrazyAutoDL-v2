'use strict';

const { test, mock } = require('node:test');
const assert = require('node:assert/strict');
const { instance } = require('./helpers');
const { AutoDLAPI, AutoDLError } = require('../src/main/api');
const { BillingSnapshot } = require('../src/main/models');
const realFetch = global.fetch;

function jsonResponse(payload) {
  return { status: 200, ok: true, text: async () => JSON.stringify(payload) };
}

test('the request timeout also covers a response body that never finishes', async (t) => {
  t.after(() => {
    global.fetch = realFetch;
    mock.timers.reset();
  });
  mock.timers.enable({ apis: ['setTimeout'] });
  global.fetch = (url, { signal }) =>
    Promise.resolve({
      status: 200,
      ok: true,
      text: () =>
        new Promise((resolve, reject) => {
          signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
        }),
    });

  const pending = new AutoDLAPI('t').request('GET', '/wallet');
  const outcome = pending.then(
    () => null,
    (error) => error
  );
  await new Promise((resolve) => setImmediate(resolve));
  mock.timers.tick(20000);
  const error = await outcome;
  assert.ok(error instanceof AutoDLError);
  assert.equal(error.kind, 'network');
  assert.match(error.message, /超时/);
});

test('stock lookup follows pagination to a host on a later page', async (t) => {
  t.after(() => {
    global.fetch = realFetch;
  });
  const target = instance('A', { machine_id: 'target' });
  const pages = [];
  global.fetch = async (url, { body }) => {
    const request = JSON.parse(body);
    pages.push(request.page_index);
    const list =
      request.page_index === 1
        ? Array.from({ length: 100 }, (_, i) => ({ machine_id: `other-${i}`, gpu_idle_num: 0 }))
        : [{ machine_id: 'target', gpu_idle_num: 2, gpu_all_num: 8 }];
    return jsonResponse({ code: 'Success', data: { list, result_total: 101 } });
  };
  const stock = await new AutoDLAPI('t').fetchGPUStock(target);
  assert.deepEqual(pages, [1, 2]);
  assert.equal(stock.machineFound, true);
  assert.equal(stock.idleGPUs, 2);
  assert.equal(stock.incomplete, false);
  assert.equal(stock.instanceId, 'A');
});

test('a host that really is absent ends the search without claiming incompleteness', async (t) => {
  t.after(() => {
    global.fetch = realFetch;
  });
  let calls = 0;
  global.fetch = async () => {
    calls += 1;
    return jsonResponse({ code: 'Success', data: { list: [{ machine_id: 'x', gpu_idle_num: 1 }], result_total: 1 } });
  };
  const stock = await new AutoDLAPI('t').fetchGPUStock(instance('A'));
  assert.equal(calls, 1);
  assert.equal(stock.machineFound, false);
  assert.equal(stock.incomplete, false);
});

test('hitting the page cap is reported as incomplete', async (t) => {
  t.after(() => {
    global.fetch = realFetch;
  });
  let calls = 0;
  global.fetch = async () => {
    calls += 1;
    const list = Array.from({ length: 100 }, (_, i) => ({ machine_id: `m-${calls}-${i}`, gpu_idle_num: 0 }));
    return jsonResponse({ code: 'Success', data: { list, result_total: 100000 } });
  };
  const stock = await new AutoDLAPI('t').fetchGPUStock(instance('A'));
  assert.equal(calls, 10);
  assert.equal(stock.machineFound, false);
  assert.equal(stock.incomplete, true);
});

test('a refund larger than the day\'s charges offsets spend on other days', () => {
  const now = new Date();
  const yesterday = new Date(now.getTime() - 24 * 3600 * 1000);
  const record = (id, type, amount, at) => ({ id, type, amount, createdAt: at, chargeFrom: null, gpuType: 'x' });
  const snapshot = new BillingSnapshot(
    [record('1', 'charge', 10, yesterday), record('2', 'refund', 10, now)],
    now
  );
  assert.equal(snapshot.totalSpend(7), 0);
  assert.equal(snapshot.last7Spend(), 0);
  const series = snapshot.dailySeries(2);
  assert.equal(series[1].net, -10);
  assert.equal(series[1].amount, 0, 'the chart bar stays non-negative');
  assert.equal(series[0].net, 10);
});
