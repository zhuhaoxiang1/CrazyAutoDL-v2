'use strict';

// The engine and store modules load Electron at require time; tests run in plain Node, so hand them a stand-in.
const Module = require('module');
const os = require('os');
const fs = require('fs');
const path = require('path');

const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'hunao-test-'));
const fakeElectron = {
  app: { getPath: () => userData },
  safeStorage: { isEncryptionAvailable: () => false },
};
const originalLoad = Module._load;
Module._load = function load(request, ...rest) {
  if (request === 'electron') return fakeElectron;
  return originalLoad.call(this, request, ...rest);
};

const { parseInstance } = require('../src/main/models');
const { AutoDLAPI } = require('../src/main/api');

function rawInstance(id, overrides = {}) {
  return {
    uuid: id,
    name: `inst-${id}`,
    status: 'shutdown',
    machine_id: `machine-${id}`,
    gpu_type_name: 'RTX 4090',
    req_gpu_amount: 1,
    region_sign: 'region-a',
    charge_type: 'payg',
    ...overrides,
  };
}

function instance(id, overrides) {
  return parseInstance(rawInstance(id, overrides));
}

function fakeStore(overrides = {}) {
  return {
    selectedInstanceId: null,
    autoStartEnabled: false,
    pollingInterval: 15,
    lowBalanceThreshold: 20,
    savedTokens: [],
    deleted: 0,
    deleteOk: true,
    getToken: () => null,
    saveToken(token) {
      this.savedTokens.push(token);
      return true;
    },
    deleteToken() {
      this.deleted += 1;
      return this.deleteOk;
    },
    setSelectedInstance(id) {
      this.selectedInstanceId = id;
    },
    setAutoStart() {},
    setPollInterval() {},
    setLowBalanceThreshold() {},
    ...overrides,
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

// Replaces every network method of AutoDLAPI with a scripted handler so engine behaviour can be driven offline.
const handlers = {};
let fakeApiInstalled = false;
function installFakeApi() {
  if (fakeApiInstalled) return;
  fakeApiInstalled = true;
  for (const name of ['fetchInstances', 'fetchBalance', 'fetchGPUStock', 'powerOn', 'powerOff', 'fetchBills']) {
    AutoDLAPI.prototype[name] = function scripted(...args) {
      if (!handlers[name]) throw new Error(`unscripted AutoDLAPI.${name}`);
      return handlers[name](...args);
    };
  }
}

function stockFor(inst, idle) {
  return {
    instanceId: inst.id,
    machineID: inst.machineID,
    gpuName: inst.gpuName,
    requiredGPUs: inst.gpuCount,
    idleGPUs: idle,
    totalGPUs: 8,
    machineFound: true,
    incomplete: false,
    checkedAt: new Date(),
  };
}

function wallet() {
  return { cash: 100, blocked: 0, voucher: 0, paymentMethod: null, fetchedAt: new Date() };
}

async function signedInEngine(list, { store = fakeStore(), selected } = {}) {
  installFakeApi();
  const { Engine } = require('../src/main/engine');
  if (selected) store.selectedInstanceId = selected;
  handlers.fetchInstances = async () => list;
  handlers.fetchBalance = async () => wallet();
  handlers.fetchGPUStock = async (inst) => stockFor(inst, 0);
  const engine = new Engine({ store, demoMode: false, notify: () => false, appVersion: 'test' });
  engine.startMonitoring = () => {};
  const toasts = [];
  engine.on('toast', (toast) => toasts.push(toast));
  const result = await engine.signIn('test-token');
  assert(result.ok, 'sign-in should succeed');
  return { engine, store, toasts };
}

function assert(condition, message) {
  if (!condition) throw new Error(message || 'assertion failed');
}

module.exports = { handlers, instance, rawInstance, fakeStore, deferred, stockFor, wallet, signedInEngine, userData };
