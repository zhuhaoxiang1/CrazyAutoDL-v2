'use strict';

const { EventEmitter } = require('events');
const { AutoDLAPI, userMessage, defaultBillingRange, AutoDLError } = require('./api');
const { maskToken } = require('./store');
const {
  instanceState,
  instanceView,
  balanceView,
  stockView,
  billingView,
  BillingSnapshot,
  formatFullDate,
  formatRelative,
  formatTime,
} = require('./models');
const demo = require('./demo');

const MIN_POLL_INTERVAL = 8;
const MAX_POLL_INTERVAL = 120;
const AUTO_START_COOLDOWN_MS = 60 * 1000;

class Engine extends EventEmitter {
  constructor({ store, demoMode, notify, onSessionCleared, appVersion }) {
    super();
    this.store = store;
    this.demoMode = Boolean(demoMode);
    this.notifyHook = notify || (() => false);
    this.onSessionCleared = onSessionCleared || (() => {});
    this.appVersion = appVersion;

    this.phase = 'checking';
    this.instances = [];
    this.selectedInstanceId = store.selectedInstanceId;
    this.stock = null;
    this.balance = null;
    this.balanceError = null;
    this.billing = null;
    this.billingError = null;
    this.isBillingLoading = false;
    this.isRefreshing = false;
    this.lastUpdated = null;
    this.lastError = null;
    this.activity = [];
    this.isLoggingIn = false;
    this.loginError = null;
    this.token = null;
    this.tokenHint = '';
    this.signedInAt = null;
    this.actionInstanceId = null;
    this.isAutoStarting = false;
    this.autoStartingId = null;
    this.autoStartEnabled = store.autoStartEnabled;
    // While paused nothing polls in the background and nothing alerts or auto-starts; a manual refresh still shows data.
    this.monitoringPaused = Boolean(store.monitoringPaused);
    this.pollInterval = store.pollingInterval;
    this.lowBalanceThreshold = store.lowBalanceThreshold;
    this.gpuWasAvailable = false;
    this.didNotifyForAvailability = false;
    this.didNotifyForLowBalance = false;
    this.lastAutoAttemptAt = null;
    this.consecutiveErrors = 0;
    this.activitySequence = 0;
    this.monitorGeneration = 0;
    // Bumped whenever the signed-in session changes (login, logout, expiry). Every async path captures it up front and
    // drops its result, errors included, if it no longer matches, so a late reply from an old session cannot touch the new one.
    this.sessionId = 0;
    // Bumped whenever the monitored target changes, so a stock reply fetched for the old target is never applied to the new one.
    this.targetVersion = 0;
    // Set while the selected instance has dropped out of the list: automation stays paused until the user picks a target.
    this.targetLost = null;
    // Instance ids with a power request in flight or awaiting confirmation. Manual and automatic power-ons share it.
    this.busy = new Set();
    this.refreshLoop = null;
    this.pendingRefresh = false;
    this.monitorStopped = true;
    this.destroyed = false;

    if (this.demoMode) {
      this.phase = 'loggedOut';
      this.applyDemo();
      return;
    }

    store.onSaveError = (error) => {
      this.emitToast('error', '设置未能保存', `写入本地配置失败，重启后可能恢复旧值：${error && error.message ? error.message : error}`);
    };

    const savedToken = store.getToken();
    if (savedToken) {
      this.token = savedToken;
      this.tokenHint = maskToken(savedToken);
      this.phase = 'checking';
      this.connectWithToken(savedToken, { persist: false, bootstrap: true }).catch((error) => {
        console.error('[engine] bootstrap failed:', error);
      });
    } else {
      this.phase = 'loggedOut';
    }
  }

  applyDemo() {
    const seed = demo.seed();
    this.phase = 'signedIn';
    this.signedInAt = new Date(Date.now() - 3 * 24 * 60 * 60 * 1000);
    this.instances = seed.instances;
    this.selectedInstanceId = seed.selectedInstanceId;
    this.stock = seed.stock;
    this.balance = seed.balance;
    this.billing = new BillingSnapshot(seed.billing.records, seed.billing.fetchedAt);
    this.activity = seed.activity;
    this.lastUpdated = new Date();
    this.tokenHint = 'demo••••••••';
    this.autoStartEnabled = true;
    this.pollInterval = 15;
    this.emitState();
  }

  destroy() {
    this.destroyed = true;
    this.stopMonitoring();
    this.removeAllListeners();
  }

  // ---------------------------------------------------------------- session

  isCurrent(sid) {
    return sid === this.sessionId && this.phase === 'signedIn' && !this.destroyed;
  }

  // Drops all in-flight bookkeeping when the session changes; stale callbacks are filtered by sessionId.
  resetOperations() {
    this.refreshLoop = null;
    this.pendingRefresh = false;
    this.isRefreshing = false;
    this.isBillingLoading = false;
    this.isAutoStarting = false;
    this.autoStartingId = null;
    this.actionInstanceId = null;
    this.busy.clear();
  }

  async connectWithToken(rawToken, { persist, bootstrap } = {}) {
    const candidate = String(rawToken || '').trim();
    if (!candidate) return { ok: false, error: '请输入 AutoDL Token' };
    if (this.isLoggingIn) return { ok: false, error: '正在连接，请稍候' };

    this.isLoggingIn = true;
    this.loginError = null;
    this.emitState();

    const startSid = this.sessionId;
    const api = new AutoDLAPI(candidate);
    try {
      const list = await api.fetchInstances();
      this.sessionId += 1;
      this.resetOperations();
      this.token = candidate;
      this.tokenHint = maskToken(candidate);
      this.phase = 'signedIn';
      this.signedInAt = new Date();
      this.loginError = null;
      this.lastError = null;
      this.applyInstances(list);
      this.addActivity(
        'success',
        bootstrap ? '已自动连接 AutoDL' : '登录成功',
        list.length === 0 ? '账号下暂无实例' : `正在守护 ${list.length} 个实例`
      );
      if (list.length === 0) {
        this.addActivity('info', '账号下暂无实例', '请先在 AutoDL 控制台创建实例');
      }
      if (persist && !this.store.saveToken(candidate)) {
        const detail = '本次登录有效，但凭证未能写入本地，下次启动需要重新登录。';
        this.addActivity('warning', '凭证未能保存', detail);
        this.emitToast('warning', '凭证未能保存', detail);
      }
      this.isLoggingIn = false;
      this.emitState();
      this.startMonitoring(true);
      return { ok: true, count: list.length };
    } catch (error) {
      const message = userMessage(error);
      this.isLoggingIn = false;
      if (error instanceof AutoDLError && error.isAuthFailure) {
        if (bootstrap) {
          this.expireSession(message, startSid);
        } else {
          this.loginError = 'Token 无效或已过期，请重新登录 AutoDL';
          this.emitState();
        }
        return { ok: false, error: this.loginError || message };
      }

      if (bootstrap) {
        this.sessionId += 1;
        this.resetOperations();
        this.token = candidate;
        this.tokenHint = maskToken(candidate);
        this.phase = 'signedIn';
        this.signedInAt = new Date();
        this.lastError = message;
        this.addActivity('error', '首次同步失败', message);
        this.emitState();
        this.startMonitoring(true);
        return { ok: true, offline: true };
      }

      this.loginError = message;
      this.emitState();
      return { ok: false, error: message };
    }
  }

  async signIn(rawToken) {
    return this.connectWithToken(rawToken, { persist: true, bootstrap: false });
  }

  // Wipes the stored credential and reports a failure to the user: a token that is still on disk after sign-out
  // would silently log the next launch back in.
  clearStoredCredential() {
    const removed = this.store.deleteToken();
    this.onSessionCleared();
    if (!removed) {
      const detail = '本地凭证删除失败，下次启动可能仍会自动登录。请检查磁盘空间或文件权限，或手动删除配置文件。';
      this.loginError = detail;
      this.emitToast('error', '本地凭证删除失败', detail);
    }
    return removed;
  }

  logout() {
    if (this.demoMode) {
      this.emitToast('info', '演示模式', '演示数据不会退出登录。');
      return;
    }
    this.stopMonitoring();
    this.sessionId += 1;
    this.resetOperations();
    this.token = null;
    this.tokenHint = '';
    this.phase = 'loggedOut';
    this.signedInAt = null;
    this.instances = [];
    this.selectedInstanceId = null;
    this.targetLost = null;
    this.targetVersion += 1;
    this.stock = null;
    this.lastUpdated = null;
    this.lastError = null;
    this.loginError = null;
    this.activity = [];
    this.balance = null;
    this.balanceError = null;
    this.billing = null;
    this.billingError = null;
    this.gpuWasAvailable = false;
    this.didNotifyForAvailability = false;
    this.didNotifyForLowBalance = false;
    this.lastAutoAttemptAt = null;
    this.store.setSelectedInstance(null);
    this.clearStoredCredential();
    this.emitState();
  }

  // `sid` is the session the caller was working for; an expiry reported by a request from an older session is ignored.
  expireSession(reason, sid) {
    if (sid !== undefined && sid !== this.sessionId) return;
    this.stopMonitoring();
    this.sessionId += 1;
    this.resetOperations();
    this.token = null;
    this.tokenHint = '';
    this.phase = 'loggedOut';
    this.signedInAt = null;
    this.stock = null;
    this.balance = null;
    this.balanceError = null;
    this.billing = null;
    this.billingError = null;
    this.didNotifyForLowBalance = false;
    this.lastUpdated = null;
    this.loginError = reason;
    this.clearStoredCredential();
    if (this.loginError !== reason) this.loginError = `${reason}（${this.loginError}）`;
    this.addActivity('error', '登录已失效', reason);
    this.emitToast('error', '登录已失效', '请重新连接 AutoDL');
    this.emitState();
  }

  // -------------------------------------------------------------- monitoring

  startMonitoring(immediately) {
    const generation = ++this.monitorGeneration;
    this.monitorStopped = false;
    const loop = async () => {
      if (immediately) {
        await this.refreshAll(false);
      }
      while (!this.monitorStopped && generation === this.monitorGeneration) {
        await delay(Math.max(this.pollInterval, MIN_POLL_INTERVAL) * 1000);
        if (this.monitorStopped || generation !== this.monitorGeneration) return;
        if (this.monitoringPaused) continue;
        await this.refreshAll(false);
      }
    };
    loop().catch((error) => console.error('[engine] monitor loop failed:', error));
  }

  stopMonitoring() {
    this.monitorGeneration += 1;
    this.monitorStopped = true;
  }

  refreshNow() {
    if (this.demoMode) {
      if (this.stock) this.stock.checkedAt = new Date();
      this.lastUpdated = new Date();
      if (this.billing) this.billing.fetchedAt = new Date();
      this.emitState();
      this.emitToast('info', '演示数据已刷新', '当前展示的是内置测试账号，不会请求 AutoDL。');
      return;
    }
    this.refreshAll(true);
  }

  // One loop at a time. A call made while a refresh is running queues exactly one more pass and resolves when the
  // whole loop is done, so a target switch or a post-power-action check always ends up reading fresh data.
  refreshAll(userInitiated = false) {
    if (this.demoMode || this.phase !== 'signedIn' || !this.token) return Promise.resolve();
    if (this.refreshLoop) {
      this.pendingRefresh = true;
      return this.refreshLoop;
    }

    const sid = this.sessionId;
    const loop = (async () => {
      try {
        let first = userInitiated;
        do {
          this.pendingRefresh = false;
          await this.refreshOnce(sid, first);
          first = false;
        } while (this.pendingRefresh && this.isCurrent(sid));
      } finally {
        if (this.refreshLoop === loop) this.refreshLoop = null;
      }
    })();
    this.refreshLoop = loop;
    return loop;
  }

  async refreshOnce(sid, userInitiated) {
    const token = this.token;
    this.isRefreshing = true;
    this.emitState();

    try {
      const list = await new AutoDLAPI(token).fetchInstances();
      if (!this.isCurrent(sid)) return;

      this.applyInstances(list);
      this.lastError = null;
      this.consecutiveErrors = 0;

      try {
        const latestBalance = await new AutoDLAPI(token).fetchBalance();
        if (!this.isCurrent(sid)) return;
        this.balance = latestBalance;
        this.balanceError = null;
        this.evaluateBalanceAlert();
      } catch (error) {
        if (!this.isCurrent(sid)) return;
        if (error instanceof AutoDLError && error.isAuthFailure) {
          this.expireSession(userMessage(error), sid);
          return;
        }
        this.balanceError = userMessage(error);
      }

      const selected = this.selectedInstance;
      if (!selected) {
        this.stock = null;
        this.lastUpdated = new Date();
        return;
      }

      const targetVersion = this.targetVersion;
      try {
        const latestStock = await new AutoDLAPI(token).fetchGPUStock(selected);
        if (!this.isCurrent(sid) || targetVersion !== this.targetVersion) return;
        const current = this.selectedInstance;
        if (!current || !stockMatches(latestStock, current)) return;
        this.stock = latestStock;
        this.lastUpdated = new Date();
        this.evaluateStock(latestStock, current);
      } catch (error) {
        if (!this.isCurrent(sid)) return;
        if (error instanceof AutoDLError && error.isAuthFailure) {
          this.expireSession(userMessage(error), sid);
          return;
        }
        if (targetVersion !== this.targetVersion) return;
        this.lastError = `显卡状态同步失败：${userMessage(error)}`;
        this.stock = null;
        this.lastUpdated = new Date();
        this.registerFailure(this.lastError);
      }
    } catch (error) {
      if (!this.isCurrent(sid)) return;
      if (error instanceof AutoDLError && error.isAuthFailure) {
        this.expireSession(userMessage(error), sid);
        return;
      }
      this.lastError = userMessage(error);
      this.registerFailure(this.lastError);
      if (userInitiated) {
        this.emitToast('error', '同步失败', this.lastError);
      }
    } finally {
      if (sid === this.sessionId) {
        this.isRefreshing = false;
        this.emitState();
      }
    }
  }

  // ----------------------------------------------------------------- billing

  async refreshBilling(force = false) {
    if (this.phase !== 'signedIn') return;
    if (this.demoMode) {
      if (this.billing) this.billing.fetchedAt = new Date();
      this.emitState();
      this.emitToast('info', '演示账单已是最新', '内置测试账号的近 35 天流水已加载。');
      return;
    }
    if (this.isBillingLoading) return;
    if (!force && this.billing && Date.now() - this.billing.fetchedAt.getTime() < 120 * 1000) {
      return;
    }

    const sid = this.sessionId;
    const token = this.token;
    this.isBillingLoading = true;
    this.emitState();

    try {
      const { start, end } = defaultBillingRange();
      const records = await new AutoDLAPI(token).fetchBills(start, end);
      if (!this.isCurrent(sid)) return;
      this.billing = new BillingSnapshot(records, new Date());
      this.billingError = null;
    } catch (error) {
      if (!this.isCurrent(sid)) return;
      if (error instanceof AutoDLError && error.isAuthFailure) {
        this.expireSession(userMessage(error), sid);
        return;
      }
      this.billingError = userMessage(error);
    } finally {
      if (sid === this.sessionId) {
        this.isBillingLoading = false;
        this.emitState();
      }
    }
  }

  // --------------------------------------------------------------- selection

  applyInstances(list) {
    const previousList = this.instances;
    const previousSelection = this.selectedInstanceId;
    const stored = this.store.selectedInstanceId;
    this.instances = list;

    // Only the very first pick may fall back to the head of the list. Once a target exists and then goes missing
    // (released, or just absent from one response), keep it, pause automation and make the user choose again; silently
    // moving to another instance could power on something they never selected.
    const wanted = [stored, previousSelection].filter(Boolean);
    const next = wanted.map((id) => list.find((instance) => instance.id === id)).find(Boolean) || null;
    const wasLost = Boolean(this.targetLost);

    if (next) {
      this.selectedInstanceId = next.id;
      this.targetLost = null;
      if (next.id !== stored) this.store.setSelectedInstance(next.id);
      if (wasLost) this.addActivity('info', '监控目标已恢复', `${next.name} 重新出现在实例列表中`);
    } else if (wanted.length > 0) {
      this.selectedInstanceId = wanted[0];
      if (!wasLost) {
        const known = previousList.find((instance) => wanted.includes(instance.id));
        const name = known ? known.name : wanted[0];
        this.targetLost = { id: wanted[0], name };
        this.addActivity('warning', '监控目标已消失', `${name} 不在实例列表中，已暂停自动开机，请重新选择监控目标`);
        this.emitToast('warning', '监控目标已消失', `${name} 不在实例列表中，已暂停自动开机。`);
      }
    } else {
      const first = list[0] || null;
      this.selectedInstanceId = first ? first.id : null;
      this.targetLost = null;
      if (first) this.store.setSelectedInstance(first.id);
    }

    const effective = this.selectedInstance ? this.selectedInstanceId : null;
    const previousEffective = previousList.some((instance) => instance.id === previousSelection)
      ? previousSelection
      : null;
    if (effective !== previousEffective) this.resetTargetState();
  }

  resetTargetState() {
    this.targetVersion += 1;
    this.stock = null;
    this.lastUpdated = null;
    this.gpuWasAvailable = false;
    this.didNotifyForAvailability = false;
    this.lastAutoAttemptAt = null;
  }

  selectInstance(id) {
    if (id === this.selectedInstanceId && !this.targetLost) return;
    const instance = this.instances.find((item) => item.id === id);
    if (!instance) return;
    this.selectedInstanceId = id;
    this.targetLost = null;
    this.store.setSelectedInstance(id);
    this.resetTargetState();
    this.lastError = null;
    this.addActivity('info', '已切换监控目标', `${instance.name} · ${instance.gpuName}`);
    this.emitState();
    if (!this.demoMode) this.refreshAll(true);
  }

  get selectedInstance() {
    if (!this.selectedInstanceId) return null;
    return this.instances.find((instance) => instance.id === this.selectedInstanceId) || null;
  }

  // -------------------------------------------------------------- automation

  evaluateStock(stock, instance) {
    if (this.monitoringPaused || !stockMatches(stock, instance)) return;
    const available = stockAvailable(stock);
    const isPoweredOff = instanceState(instance.rawStatus) === 'stopped';

    if (available && !this.gpuWasAvailable) {
      this.addActivity(
        'warning',
        '发现空闲显卡',
        `${instance.machineID} · ${stock.idleGPUs} 张 ${instance.gpuName} 空闲`
      );
      if (this.autoStartEnabled) {
        this.addActivity('info', '自动开机已触发', '正在尝试抢占空闲 GPU');
      }
    }

    this.gpuWasAvailable = available;
    if (!available) {
      this.didNotifyForAvailability = false;
      return;
    }
    if (!isPoweredOff) return;

    if (this.autoStartEnabled) {
      this.attemptAutoPowerOn(instance, stock);
    } else if (!this.didNotifyForAvailability) {
      this.didNotifyForAvailability = true;
      this.notifyGPUAvailable(instance, stock);
    }
  }

  notifyGPUAvailable(instance, stock) {
    const title = '发现空闲 GPU';
    const body = `${instance.name} 所在主机有 ${stock.idleGPUs} 张 ${instance.gpuName} 空闲，自动开机已关闭。`;
    this.addActivity('warning', '已发送空闲提醒', body);
    this.emitToast('warning', title, body);
    this.notifyHook({ title, body, tag: `gpu-available-${instance.id}` });
  }

  setAutoStart(enabled) {
    const next = Boolean(enabled);
    if (this.autoStartEnabled === next) return;
    this.autoStartEnabled = next;
    if (!this.demoMode) this.store.setAutoStart(next);

    if (next) {
      this.addActivity('info', '自动开机已开启', '检测到空闲显卡后自动抢占');
      const instance = this.selectedInstance;
      if (instance && instanceState(instance.rawStatus) === 'stopped' && this.stock) {
        if (stockMatches(this.stock, instance) && stockAvailable(this.stock)) {
          this.attemptAutoPowerOn(instance, this.stock);
        }
      }
    } else {
      this.addActivity('info', '自动开机已关闭', '之后仅在有卡空闲时提醒');
      const instance = this.selectedInstance;
      const stock = this.stock ? stockView(this.stock) : null;
      if (
        instance &&
        instanceState(instance.rawStatus) === 'stopped' &&
        stock &&
        stock.isAvailable &&
        !this.didNotifyForAvailability
      ) {
        this.didNotifyForAvailability = true;
        this.notifyGPUAvailable(instance, this.stock);
      }
    }
    this.emitState();
  }

  setMonitoringPaused(paused) {
    const next = Boolean(paused);
    if (this.monitoringPaused === next) return;
    this.monitoringPaused = next;
    if (!this.demoMode) this.store.setMonitoringPaused(next);
    if (next) {
      this.addActivity('info', '监控已暂停', '不再后台轮询，也不会提醒或自动开机');
    } else {
      // Start a fresh episode so a card that is free right now is reported once on resume.
      this.gpuWasAvailable = false;
      this.didNotifyForAvailability = false;
      this.addActivity('info', '监控已恢复', '重新开始轮询与提醒');
    }
    this.emitState();
    if (!next && !this.demoMode && this.phase === 'signedIn') this.refreshAll(false);
  }

  setPollInterval(seconds) {
    const normalized = Math.min(Math.max(Math.round(Number(seconds) || 0), MIN_POLL_INTERVAL), MAX_POLL_INTERVAL);
    if (normalized === this.pollInterval) return;
    this.pollInterval = normalized;
    if (!this.demoMode) this.store.setPollInterval(normalized);
    this.addActivity('info', '刷新间隔已调整', `每 ${normalized} 秒检查一次`);
    this.emitState();
    if (!this.demoMode && this.phase === 'signedIn') this.startMonitoring(false);
  }

  setLowBalanceThreshold(value) {
    const normalized = Math.min(Math.max(Math.round((Number(value) || 0) * 100) / 100, 1), 10000);
    if (Math.abs(normalized - this.lowBalanceThreshold) < 0.001) return;
    this.lowBalanceThreshold = normalized;
    if (!this.demoMode) this.store.setLowBalanceThreshold(normalized);
    this.addActivity('info', '余额提醒阈值已更新', `可用余额低于 ¥${normalized.toFixed(2)} 时提醒`);
    this.emitState();
    if (!this.balance) return;
    const available = Math.max(0, this.balance.cash) + Math.max(0, this.balance.voucher);
    if (available >= normalized) {
      this.didNotifyForLowBalance = false;
    } else {
      this.evaluateBalanceAlert();
    }
  }

  evaluateBalanceAlert() {
    if (!this.balance || this.monitoringPaused) return;
    const available = Math.max(0, this.balance.cash) + Math.max(0, this.balance.voucher);
    if (available >= this.lowBalanceThreshold) {
      this.didNotifyForLowBalance = false;
      return;
    }
    if (this.didNotifyForLowBalance) return;
    this.didNotifyForLowBalance = true;

    const title = '余额不足提醒';
    const voucherNote =
      this.balance.voucher > 0
        ? `（含代金券 ¥${this.balance.voucher.toFixed(2)}）`
        : '';
    const body = `AutoDL 可用余额 ¥${available.toFixed(2)}${voucherNote}，已低于 ¥${this.lowBalanceThreshold.toFixed(2)}，请及时充值以免影响自动开机。`;
    this.addActivity('warning', title, body);
    this.emitToast('warning', title, body);
    this.notifyHook({ title, body, tag: 'balance-low' });
  }

  // Marks an instance as having a power request outstanding. Held from sending the request until the follow-up
  // refresh has had a chance to show the new status, so a second request cannot race the first.
  claimInstance(sid, id) {
    if (sid !== this.sessionId || this.busy.has(id)) return false;
    this.busy.add(id);
    return true;
  }

  releaseInstance(sid, id) {
    if (sid !== this.sessionId) return;
    this.busy.delete(id);
    if (this.actionInstanceId === id) this.actionInstanceId = null;
    if (this.autoStartingId === id) {
      this.autoStartingId = null;
      this.isAutoStarting = false;
    }
    this.emitState();
  }

  confirmThenRelease(sid, id, waitMs) {
    setTimeout(async () => {
      try {
        if (this.isCurrent(sid)) await this.refreshAll(false);
      } catch (error) {
        console.error('[engine] post-power refresh failed:', error);
      } finally {
        this.releaseInstance(sid, id);
      }
    }, waitMs);
  }

  async attemptAutoPowerOn(instance, stock) {
    if (this.demoMode) return;
    if (!this.autoStartEnabled || this.monitoringPaused || this.phase !== 'signedIn') return;
    const current = this.selectedInstance;
    if (!current || current.id !== instance.id || this.targetLost) return;
    if (instanceState(current.rawStatus) !== 'stopped') return;
    if (!stockMatches(stock, current) || !stockAvailable(stock)) return;
    if (this.lastAutoAttemptAt && Date.now() - this.lastAutoAttemptAt.getTime() < AUTO_START_COOLDOWN_MS) {
      return;
    }

    const token = this.token;
    const sid = this.sessionId;
    if (!token || !this.claimInstance(sid, current.id)) return;
    this.isAutoStarting = true;
    this.autoStartingId = current.id;
    this.lastAutoAttemptAt = new Date();
    this.emitState();

    let confirming = false;
    try {
      await new AutoDLAPI(token).powerOn(current.id);
      if (sid !== this.sessionId) return;
      const title = '自动开机成功';
      const detail = `${current.name} 正在启动，已抢占 ${stock.idleGPUs} 张空闲 ${current.gpuName}`;
      this.addActivity('success', title, detail);
      this.emitToast('success', title, detail);
      this.notifyHook({ title, body: detail, tag: `autostart-${current.id}` });
      confirming = true;
      this.confirmThenRelease(sid, current.id, 2500);
    } catch (error) {
      if (sid !== this.sessionId) return;
      if (error instanceof AutoDLError && error.isAuthFailure) {
        this.expireSession(userMessage(error), sid);
        return;
      }
      const detail = userMessage(error);
      this.addActivity('error', '自动开机失败', detail);
      this.emitToast('error', '自动开机失败', detail);
    } finally {
      if (!confirming) this.releaseInstance(sid, current.id);
    }
  }

  async performPowerAction(instance, turnOn) {
    if (!instance) return;
    if (this.demoMode) {
      this.applyDemoPowerAction(instance, turnOn);
      return;
    }
    if (this.phase !== 'signedIn' || !this.token) return;

    const token = this.token;
    const sid = this.sessionId;
    if (!this.claimInstance(sid, instance.id)) {
      this.emitToast('info', '实例正在处理指令', `${instance.name} 上一条开关机请求尚未完成，请稍候。`);
      return;
    }
    this.actionInstanceId = instance.id;
    this.emitState();

    let confirming = false;
    try {
      const api = new AutoDLAPI(token);
      if (turnOn) await api.powerOn(instance.id);
      else await api.powerOff(instance.id);
      if (sid !== this.sessionId) return;
      const title = turnOn ? '开机指令已发送' : '关机指令已发送';
      this.addActivity('success', title, instance.name);
      this.emitToast('success', title, `${instance.name} 状态将在几秒后同步。`);
      confirming = true;
      this.confirmThenRelease(sid, instance.id, 2000);
    } catch (error) {
      if (sid !== this.sessionId) return;
      if (error instanceof AutoDLError && error.isAuthFailure) {
        this.expireSession(userMessage(error), sid);
        return;
      }
      const title = turnOn ? '开机失败' : '关机失败';
      const message = userMessage(error);
      this.addActivity('error', title, message);
      this.emitToast('error', title, message);
    } finally {
      if (!confirming) this.releaseInstance(sid, instance.id);
    }
  }

  applyDemoPowerAction(instance, turnOn) {
    const title = turnOn ? '开机指令已发送' : '关机指令已发送';
    instance.rawStatus = turnOn ? 'starting' : 'stopping';
    instance.statusAt = new Date();
    this.actionInstanceId = instance.id;
    this.addActivity('success', title, instance.name);
    this.emitToast('success', title, `${instance.name} 状态将在几秒后同步。`);
    this.emitState();

    setTimeout(() => {
      instance.rawStatus = turnOn ? 'running' : 'shutdown';
      instance.statusAt = new Date();
      if (turnOn) instance.startedAt = new Date();
      this.actionInstanceId = null;
      if (turnOn) {
        this.stock = null;
      } else if (this.stock) {
        this.stock.checkedAt = new Date();
      }
      this.lastUpdated = new Date();
      this.addActivity(turnOn ? 'success' : 'info', turnOn ? '实例已启动' : '实例已关机', instance.name);
      this.emitState();
    }, 2200);
  }

  powerOn(id) {
    const instance = this.instances.find((item) => item.id === id);
    if (!instance) return;
    this.performPowerAction(instance, true);
  }

  powerOff(id) {
    const instance = this.instances.find((item) => item.id === id);
    if (!instance) return;
    this.performPowerAction(instance, false);
  }

  sendTestNotification() {
    const delivered = this.notifyHook({
      title: '胡闹AutoDL 测试通知',
      body: '通知通道正常。发现空闲 GPU 或余额不足时，会在这里提醒你。',
      tag: 'test-notification',
    });
    if (delivered) {
      this.emitToast('info', '测试通知已发送', '如果桌面没有出现横幅，请检查 Windows 通知设置。');
    } else {
      this.emitToast('warning', '通知发送失败', '当前系统不支持通知，或通知已被关闭。');
    }
    return delivered;
  }

  // --------------------------------------------------------------- utilities

  addActivity(kind, title, detail = '') {
    this.activitySequence += 1;
    this.activity.unshift({
      id: `activity-${Date.now()}-${this.activitySequence}`,
      date: new Date(),
      kind,
      title,
      detail,
    });
    if (this.activity.length > 40) this.activity = this.activity.slice(0, 40);
  }

  emitToast(kind, title, message) {
    this.emit('toast', {
      id: `toast-${Date.now()}-${Math.random().toString(36).slice(2, 7)}`,
      kind,
      title,
      message,
    });
  }

  registerFailure(message) {
    this.consecutiveErrors += 1;
    if (this.consecutiveErrors === 1 || this.consecutiveErrors % 10 === 0) {
      this.addActivity('error', '监控同步异常', message);
    }
  }

  emitState() {
    if (this.destroyed) return;
    this.emit('state', this.buildState());
  }

  buildState() {
    const selectedRaw = this.selectedInstance;
    const selected = instanceView(selectedRaw);
    const stock = stockView(this.stock);
    const balance = balanceView(this.balance);
    const billing = billingView(this.billing, balance ? balance.available : null);
    const isLowBalance = balance ? balance.available < this.lowBalanceThreshold : false;
    const state = selected ? selected.state : null;

    let headline = '等待选择实例';
    let caption = '先在 AutoDL 创建一个实例';
    if (selected) {
      if (!stock) {
        headline = this.lastError ? '显卡状态暂不可用' : '正在读取显卡状态';
        caption = `刷新间隔 ${this.pollInterval} 秒`;
      } else if (state === 'running') {
        headline = selected.isNoCardMode
          ? '实例以无卡模式运行'
          : selected.isGPUMode
            ? '实例正在使用 GPU'
            : '实例运行中';
      } else if (state === 'starting') {
        headline = '实例正在启动';
      } else if (state === 'stopping') {
        headline = '实例正在关机';
      } else if (stock.isAvailable) {
        headline = '发现空闲显卡';
      } else if (stock.incomplete) {
        headline = '库存查询不完整';
      } else if (!stock.machineFound) {
        headline = '目标主机暂未放出空卡';
      } else {
        headline = '正在等待空闲显卡';
      }

      if (stock) {
        if (stock.isAvailable) {
          caption = this.autoStartEnabled ? '自动开机已就绪' : '自动开机已关闭，仅发送提醒';
        } else if (stock.incomplete) {
          caption = `目标主机不在已查询的结果页内，无法判断是否有空卡`;
        } else if (!stock.machineFound) {
          caption = `目标主机 ${selectedRaw.machineID || 'ID 缺失'} 暂无空闲卡`;
        } else {
          caption = `已监测目标主机 · ${this.pollInterval} 秒刷新`;
        }
      }
    }

    if (!selected && this.targetLost) {
      headline = '监控目标已消失';
      caption = `「${this.targetLost.name}」不在实例列表中，已暂停自动开机，请重新选择监控目标`;
    }

    if (this.monitoringPaused && selected) {
      headline = '监控已暂停';
      caption = '不再后台轮询、提醒或自动开机，点击“恢复监控”继续';
    }

    let autoStartSubtitle = '只提醒，不自动开机';
    if (this.autoStartEnabled) {
      autoStartSubtitle = this.monitoringPaused
        ? '监控已暂停，自动开机不会触发'
        : this.targetLost
        ? '监控目标已消失，自动开机已暂停'
        : state === 'stopped'
          ? '守候空闲卡，出现即开机'
          : '等待实例关机后接管';
    }

    return {
      phase: this.phase,
      isDemo: this.demoMode,
      version: this.appVersion,
      todayLabel: formatFullDate(new Date()),
      isLoggingIn: this.isLoggingIn,
      loginError: this.loginError,
      tokenHint: this.tokenHint,
      signedInAt: this.signedInAt ? this.signedInAt.toISOString() : null,
      instances: this.instances.map(instanceView),
      selectedInstanceId: this.selectedInstanceId,
      selectedInstance: selected,
      stock,
      balance,
      balanceError: this.balanceError,
      billing,
      billingError: this.billingError,
      isBillingLoading: this.isBillingLoading,
      isRefreshing: this.isRefreshing,
      isAutoStarting: this.isAutoStarting,
      actionInstanceId: this.actionInstanceId,
      busyInstanceIds: [...this.busy],
      targetLost: this.targetLost,
      autoStartEnabled: this.autoStartEnabled,
      monitoringPaused: this.monitoringPaused,
      autoStartSubtitle,
      pollInterval: this.pollInterval,
      lowBalanceThreshold: this.lowBalanceThreshold,
      isLowBalance,
      lastUpdated: this.lastUpdated ? this.lastUpdated.toISOString() : null,
      lastUpdatedLabel: formatRelative(this.lastUpdated),
      lastError: this.lastError,
      availabilityHeadline: headline,
      availabilityCaption: caption,
      runningCount: this.instances.filter((instance) => instanceState(instance.rawStatus) === 'running').length,
      activity: this.activity.slice(0, 12).map((event) => ({
        id: event.id,
        kind: event.kind,
        title: event.title,
        detail: event.detail,
        time: formatTime(event.date),
        date: event.date.toISOString(),
      })),
      activityCount: this.activity.length,
    };
  }
}

function stockAvailable(stock) {
  return Boolean(stock) && stock.machineFound && stock.idleGPUs > 0 && stock.idleGPUs >= Math.max(stock.requiredGPUs, 1);
}

// A stock reading only means something for the exact instance/host/requirement it was fetched for.
function stockMatches(stock, instance) {
  return (
    Boolean(stock) &&
    Boolean(instance) &&
    stock.instanceId === instance.id &&
    stock.machineID === instance.machineID &&
    stock.requiredGPUs === instance.gpuCount &&
    stock.gpuName === instance.gpuName
  );
}

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

module.exports = { Engine, stockMatches, stockAvailable };
