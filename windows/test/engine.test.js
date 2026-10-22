'use strict';

const { test, afterEach } = require('node:test');
const assert = require('node:assert/strict');
const { handlers, instance, deferred, stockFor, signedInEngine, fakeStore, wallet } = require('./helpers');
const { AutoDLError } = require('../src/main/api');

const engines = [];
afterEach(() => {
  for (const engine of engines.splice(0)) engine.destroy();
});
async function setup(...args) {
  const ctx = await signedInEngine(...args);
  engines.push(ctx.engine);
  return ctx;
}
const tick = () => new Promise((resolve) => setImmediate(resolve));

test('a vanished target pauses automation instead of moving to another instance', async () => {
  const a = instance('A');
  const b = instance('B');
  const { engine, store } = await setup([a, b], { selected: 'A' });
  assert.equal(engine.selectedInstanceId, 'A');

  const powerOns = [];
  handlers.powerOn = async (id) => powerOns.push(id);
  handlers.fetchInstances = async () => [b];
  handlers.fetchGPUStock = async (inst) => stockFor(inst, 4);
  engine.setAutoStart(true);
  await engine.refreshAll(false);

  assert.equal(engine.selectedInstance, null);
  assert.equal(engine.targetLost.id, 'A');
  assert.equal(store.selectedInstanceId, 'A', 'stored selection must survive so the target can come back');
  assert.deepEqual(powerOns, []);
  const state = engine.buildState();
  assert.equal(state.availabilityHeadline, '监控目标已消失');

  handlers.fetchInstances = async () => [a, b];
  await engine.refreshAll(false);
  assert.equal(engine.targetLost, null);
  assert.equal(engine.selectedInstanceId, 'A');

  engine.selectInstance('B');
  assert.equal(engine.targetLost, null);
});

test('a stock reply for the previous target is dropped after switching', async () => {
  const a = instance('A', { req_gpu_amount: 1 });
  const b = instance('B', { req_gpu_amount: 4 });
  const { engine } = await setup([a, b], { selected: 'A' });

  const powerOns = [];
  handlers.powerOn = async (id) => powerOns.push(id);
  handlers.fetchInstances = async () => [a, b];
  const pendingA = deferred();
  const calls = [];
  handlers.fetchGPUStock = async (inst) => {
    calls.push(inst.id);
    if (inst.id === 'A') return pendingA.promise;
    return stockFor(inst, 0);
  };

  const refresh = engine.refreshAll(false);
  await tick();
  await tick();
  engine.selectInstance('B');
  pendingA.resolve(stockFor(a, 1));
  await refresh;

  assert.deepEqual(calls, ['A', 'B'], 'the queued pass must refresh the new target');
  assert.equal(engine.stock.instanceId, 'B');
  assert.equal(engine.stock.idleGPUs, 0);

  // Even a stale reading left in place cannot drive B: it needs 4 cards, the reading is A's single card.
  engine.stock = stockFor(a, 1);
  engine.setAutoStart(true);
  await tick();
  assert.deepEqual(powerOns, []);
});

test('manual and automatic power-on never run concurrently', async () => {
  const a = instance('A');
  const { engine } = await setup([a], { selected: 'A' });
  engine.autoStartEnabled = true;

  let inFlight = 0;
  let maxInFlight = 0;
  let sent = 0;
  const gate = deferred();
  handlers.powerOn = async () => {
    sent += 1;
    inFlight += 1;
    maxInFlight = Math.max(maxInFlight, inFlight);
    await gate.promise;
    inFlight -= 1;
  };

  const stock = stockFor(a, 2);
  engine.stock = stock;
  engine.attemptAutoPowerOn(engine.selectedInstance, stock);
  await tick();
  engine.powerOn('A');
  await tick();
  assert.equal(sent, 1);
  assert.ok(engine.buildState().busyInstanceIds.includes('A'));

  gate.resolve();
  await tick();
  await tick();
  assert.equal(maxInFlight, 1);

  // Reverse order: a manual request holds the instance, the poll must not add an automatic one.
  const { engine: second } = await setup([a], { selected: 'A' });
  second.autoStartEnabled = true;
  sent = 0;
  const gate2 = deferred();
  handlers.powerOn = async () => {
    sent += 1;
    await gate2.promise;
  };
  second.powerOn('A');
  await tick();
  second.attemptAutoPowerOn(second.selectedInstance, stockFor(a, 2));
  await tick();
  assert.equal(sent, 1);
  gate2.resolve();
});

test('an auth failure from a previous session does not sign out the new one', async () => {
  const a = instance('A');
  const { engine, store } = await setup([a], { selected: 'A' });
  const slowBills = deferred();
  handlers.fetchBills = async () => slowBills.promise;
  const billing = engine.refreshBilling(true);
  await tick();

  engine.logout();
  handlers.fetchInstances = async () => [a];
  await engine.signIn('test-token');
  assert.equal(engine.phase, 'signedIn');
  const deletedBefore = store.deleted;

  slowBills.reject(new AutoDLError('unauthorized', '登录已失效'));
  await billing;
  assert.equal(engine.phase, 'signedIn');
  assert.equal(store.deleted, deletedBefore, 'the new session token must not be deleted');
  assert.equal(engine.isBillingLoading, false);
});

test('a stale refresh failure cannot expire a re-login with the same token', async () => {
  const a = instance('A');
  const { engine } = await setup([a], { selected: 'A' });
  const slow = deferred();
  handlers.fetchInstances = async () => slow.promise;
  const refresh = engine.refreshAll(false);
  await tick();

  handlers.fetchInstances = async () => [a];
  await engine.signIn('test-token');
  slow.reject(new AutoDLError('unauthorized', '登录已失效'));
  await refresh;
  assert.equal(engine.phase, 'signedIn');
});

test('failing to delete the stored credential is reported', async () => {
  const a = instance('A');
  const store = fakeStore({ deleteOk: false });
  const { engine, toasts } = await setup([a], { store });
  engine.logout();
  assert.equal(engine.phase, 'loggedOut');
  assert.ok(toasts.some((toast) => toast.title === '本地凭证删除失败'));
  assert.match(engine.loginError, /凭证删除失败/);
});

test('failing to save the credential after sign-in warns the user', async () => {
  const a = instance('A');
  const store = fakeStore();
  store.saveToken = () => false;
  const { toasts } = await setup([a], { store });
  assert.ok(toasts.some((toast) => toast.title === '凭证未能保存'));
});

test('a running instance reports its start mode instead of assuming GPU use', async () => {
  const noCard = instance('A', { status: 'running', start_mode: 'non_gpu' });
  const { engine } = await setup([noCard], { selected: 'A' });
  engine.stock = stockFor(noCard, 0);
  assert.equal(engine.buildState().availabilityHeadline, '实例以无卡模式运行');

  const gpu = instance('A', { status: 'running', start_mode: 'gpu' });
  engine.instances = [gpu];
  assert.equal(engine.buildState().availabilityHeadline, '实例正在使用 GPU');

  const unknown = instance('A', { status: 'running' });
  engine.instances = [unknown];
  assert.equal(engine.buildState().availabilityHeadline, '实例运行中');
});

test('incomplete stock lookups are not shown as "no free card"', async () => {
  const a = instance('A');
  const { engine } = await setup([a], { selected: 'A' });
  engine.stock = { ...stockFor(a, 0), machineFound: false, incomplete: true };
  const state = engine.buildState();
  assert.equal(state.availabilityHeadline, '库存查询不完整');
});

test('wallet helper stays importable', () => {
  assert.equal(wallet().cash, 100);
});

test('paused monitoring neither alerts nor auto-starts, and resuming starts a fresh episode', async () => {
  const a = instance('A');
  const { engine, store, toasts } = await setup([a], { selected: 'A' });
  const powerOns = [];
  handlers.powerOn = async (id) => powerOns.push(id);
  handlers.fetchGPUStock = async (inst) => stockFor(inst, 3);
  handlers.fetchBalance = async () => ({ cash: 1, blocked: 0, voucher: 0, paymentMethod: null, fetchedAt: new Date() });

  let saved = null;
  store.setMonitoringPaused = (value) => {
    saved = value;
    return true;
  };
  engine.autoStartEnabled = true;
  engine.setMonitoringPaused(true);
  assert.equal(saved, true, 'the choice is persisted');
  assert.equal(engine.buildState().availabilityHeadline, '监控已暂停');

  toasts.length = 0;
  await engine.refreshAll(true);
  assert.equal(engine.stock.idleGPUs, 3, 'a manual refresh still shows the data');
  assert.deepEqual(powerOns, [], 'no auto-start while paused');
  assert.equal(toasts.filter((toast) => toast.kind === 'warning').length, 0, 'no balance or availability popup while paused');

  engine.setMonitoringPaused(false);
  await tick();
  await tick();
  assert.deepEqual(powerOns, ['A'], 'resuming acts on a card that is free right now');
});
