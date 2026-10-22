'use strict';

const fs = require('fs');
const path = require('path');
const { app, safeStorage } = require('electron');

const DEFAULTS = {
  version: 1,
  autoStartEnabled: false,
  monitoringPaused: false,
  pollInterval: 15,
  lowBalanceThreshold: 20,
  selectedInstanceId: null,
  auth: { token: null, encryption: null, savedAt: null },
};

class Store {
  constructor() {
    this.file = path.join(app.getPath('userData'), 'config.json');
    this.data = this.load();
  }

  load() {
    try {
      const raw = fs.readFileSync(this.file, 'utf8');
      const parsed = JSON.parse(raw);
      const merged = { ...DEFAULTS, ...parsed, auth: { ...DEFAULTS.auth, ...(parsed.auth || {}) } };
      merged.autoStartEnabled = Boolean(merged.autoStartEnabled);
      merged.monitoringPaused = Boolean(merged.monitoringPaused);
      merged.pollInterval = clampNumber(merged.pollInterval, 8, 120, 15);
      merged.lowBalanceThreshold = clampNumber(merged.lowBalanceThreshold, 1, 10000, 20);
      merged.selectedInstanceId =
        typeof merged.selectedInstanceId === 'string' ? merged.selectedInstanceId : null;
      return merged;
    } catch {
      return JSON.parse(JSON.stringify(DEFAULTS));
    }
  }

  // Returns whether the settings reached disk. Failures are also reported through `onSaveError` so the UI can say so
  // instead of silently reverting on the next launch; credential paths pass `silent` and report on their own.
  save({ silent = false } = {}) {
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      const temp = `${this.file}.tmp`;
      fs.writeFileSync(temp, JSON.stringify(this.data, null, 2), { mode: 0o600 });
      fs.renameSync(temp, this.file);
      try {
        fs.chmodSync(this.file, 0o600);
      } catch {
        // Windows does not implement POSIX modes; userData is already per-user.
      }
      return true;
    } catch (error) {
      console.error('[store] failed to persist settings:', error);
      if (!silent && typeof this.onSaveError === 'function') this.onSaveError(error);
      return false;
    }
  }

  get pollingInterval() {
    return this.data.pollInterval;
  }

  get monitoringPaused() {
    return this.data.monitoringPaused;
  }

  setMonitoringPaused(paused) {
    this.data.monitoringPaused = Boolean(paused);
    return this.save();
  }

  get autoStartEnabled() {
    return this.data.autoStartEnabled;
  }

  get lowBalanceThreshold() {
    return this.data.lowBalanceThreshold;
  }

  get selectedInstanceId() {
    return this.data.selectedInstanceId;
  }

  setAutoStart(enabled) {
    this.data.autoStartEnabled = Boolean(enabled);
    this.save();
  }

  setPollInterval(seconds) {
    this.data.pollInterval = clampNumber(seconds, 8, 120, 15);
    this.save();
    return this.data.pollInterval;
  }

  setLowBalanceThreshold(value) {
    this.data.lowBalanceThreshold = clampNumber(value, 1, 10000, 20);
    this.save();
    return this.data.lowBalanceThreshold;
  }

  setSelectedInstance(id) {
    this.data.selectedInstanceId = id || null;
    this.save();
  }

  getToken() {
    const auth = this.data.auth || {};
    if (!auth.token) return null;
    try {
      if (auth.encryption === 'dpapi' && safeStorage.isEncryptionAvailable()) {
        return safeStorage.decryptString(Buffer.from(auth.token, 'base64'));
      }
      if (auth.encryption === 'plain') {
        return Buffer.from(auth.token, 'base64').toString('utf8');
      }
    } catch (error) {
      console.error('[store] failed to decrypt token:', error);
      return null;
    }
    return null;
  }

  saveToken(token) {
    const trimmed = String(token || '').trim();
    if (!trimmed) return false;

    let encryption = 'plain';
    let encoded = Buffer.from(trimmed, 'utf8').toString('base64');
    if (process.platform === 'win32' && safeStorage.isEncryptionAvailable()) {
      try {
        encoded = safeStorage.encryptString(trimmed).toString('base64');
        encryption = 'dpapi';
      } catch (error) {
        console.error('[store] DPAPI unavailable, falling back to local file:', error);
      }
    }

    const previous = this.data.auth;
    this.data.auth = {
      token: encoded,
      encryption,
      savedAt: new Date().toISOString(),
    };
    if (this.save({ silent: true })) return true;
    this.data.auth = previous;
    return false;
  }

  // True only when no copy of the token is left on disk. If rewriting the settings file fails, fall back to removing
  // the file outright: losing settings is better than keeping a credential the user just signed out of.
  deleteToken() {
    this.data.auth = { token: null, encryption: null, savedAt: null };
    if (this.save({ silent: true })) return true;
    try {
      fs.rmSync(this.file, { force: true });
      fs.rmSync(`${this.file}.tmp`, { force: true });
    } catch (error) {
      console.error('[store] failed to remove settings file:', error);
    }
    try {
      return !JSON.parse(fs.readFileSync(this.file, 'utf8')).auth?.token;
    } catch (error) {
      return error && error.code === 'ENOENT';
    }
  }

  get tokenSavedAt() {
    return this.data.auth && this.data.auth.savedAt ? this.data.auth.savedAt : null;
  }
}

function clampNumber(value, min, max, fallback) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(Math.max(number, min), max);
}

function maskToken(token) {
  if (!token) return '';
  if (token.length <= 12) return '••••••••';
  return `${token.slice(0, 5)}••••••${token.slice(-4)}`;
}

module.exports = { Store, maskToken };
