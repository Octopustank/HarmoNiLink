/**
 * PreferencesRepository.ets — Persist paired camera data
 *
 * Uses @ohos.data.preferences to store PairedCamera[] as JSON.
 * Keys cameras by name (BLE address changes between sessions).
 *
 * Based on nsg/android/.../SettingsRepository.kt
 */

import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';

const TAG = 'HarmoNiLink-Prefs';
const STORE_NAME = 'harmonilink_prefs';
const KEY_CAMERAS = 'paired_cameras';
const KEY_CONTROLLER_NAME = 'controller_name';
const KEY_CONNECT_HINT_SHOWN = 'connect_hint_shown';
const KEY_MULTI_CAM_WARNED = 'multi_cam_warned'; // beyond-N-cameras warning dismissed
const KEY_LAST_TAB = 'last_tab_index'; // last selected tab (配对/连接), persisted
const KEY_SLA_PREFIX = 'sla_'; // per-camera SLA timeline (连接健康看板), namespaced
const KEY_RATING_SHOWN = 'rating_shown'; // user tapped 去评分 (permanent — never re-prompt)
const KEY_HAS_DOWNLINK = 'has_downlink'; // a GEO write was acked at least once (rating gate)
const KEY_FIRST_DOWNLINK_TS = 'first_downlink_ts'; // first GEO-ack epoch-ms (48h age gate)
const KEY_DECLINED_AT = 'declined_at'; // last 谢绝/dismiss epoch-ms (7-day cooldown gate)
const KEY_PERMISSION_HINT_SHOWN = 'permission_hint_shown'; // location "always allow" hint shown (one-time)
const KEY_GPS_MODE = 'gps_power_mode'; // GPS sampling mode: 0=precise (default), 1=power-saving
// Suffix alphabet — no 0/O/1/I to avoid confusion when reading the name on the camera
const SUFFIX_CHARS: string = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';

interface SerializedCamera {
  name: string;
  address: string;
  addressType: number;
  device: number;
  nonce: number;
  controllerName: string;
}

export class PreferencesRepository {
  private store: preferences.Preferences | null = null;
  private cache: PairedCamera[] = []; // in-memory cache for sync access
  private controllerNameCache: string = '';
  private connectHintShownCache: boolean = false; // one-time first-connect hint shown
  private multiCamWarnedCache: boolean = false; // beyond-N-cameras warning "don't show again"
  private lastTabIndexCache: number = 0; // last selected tab
  private ratingShownCache: boolean = false; // user tapped 去评分 (permanent)
  private hasDownlinkCache: boolean = false; // a GEO write was acked at least once
  private firstDownlinkTsCache: number = 0; // first GEO-ack epoch-ms (0 = never)
  private declinedAtCache: number = 0; // last 谢绝/dismiss epoch-ms (0 = never)
  private permissionHintShownCache: boolean = false; // location "always allow" hint shown
  private gpsModeCache: number = 0; // 0=precise, 1=power-saving
  // Serialized disk writes. The CACHE is the single source of truth: it is
  // updated synchronously on every mutation, and queued tasks merely snapshot
  // it to disk. This kills the old read-disk-modify-write race where a slow
  // async save could overwrite the cache (and disk) with a STALE snapshot —
  // e.g. reverting a fresh keepAlive=true to false and snapping the UI toggle
  // off while the link stayed up.
  private saveQueue: Promise<void> = Promise.resolve();
  // Readiness barrier: init() is async, but MainPage needs the persisted tab
  // index SYNCHRONOUSLY at first render (no flash of the wrong tab). Expose
  // whenReady() so the page waits for the load to finish before reading.
  private ready: boolean = false;
  private readyResolvers: Array<() => void> = [];

  /** True once init() has loaded the persisted values. */
  isReady(): boolean { return this.ready; }

  /** Resolves when init() finishes (immediately if already ready). */
  whenReady(): Promise<void> {
    if (this.ready) return Promise.resolve();
    return new Promise<void>((resolve) => { this.readyResolvers.push(resolve); });
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, STORE_NAME);
      // One-time disk load → becomes the cache (the single source of truth
      // from here on; all mutations go through saveCameraSync/removeCamera).
      const json = await this.store.get(KEY_CAMERAS, '[]') as string;
      const arr: SerializedCamera[] = JSON.parse(json);
      const diskCams = arr.map((s) => new PairedCamera(
        s.name, s.address, s.addressType,
        s.device, s.nonce, s.controllerName
        // keepAlive intentionally NOT loaded — connection intent is
        // session-runtime state and always starts OFF on a fresh launch
      ));
      if (this.cache.length === 0) {
        this.cache = diskCams;
      } else {
        // A save already landed before init() finished (e.g. ultra-fast
        // pairing) — merge by name with the in-memory cache winning, so the
        // disk read can't resurrect-delete the freshly-paired camera.
        const byName = new Map<string, PairedCamera>();
        for (const c of diskCams) byName.set(c.name, c);
        for (const c of this.cache) byName.set(c.name, c);
        this.cache = Array.from(byName.values());
      }
      const saved = await this.store.get(KEY_CONTROLLER_NAME, '') as string;
      if (saved) this.controllerNameCache = saved; // don't overwrite a freshly generated name
      this.connectHintShownCache = await this.store.get(KEY_CONNECT_HINT_SHOWN, false) as boolean;
      this.multiCamWarnedCache = await this.store.get(KEY_MULTI_CAM_WARNED, false) as boolean;
      this.lastTabIndexCache = await this.store.get(KEY_LAST_TAB, 0) as number;
      this.ratingShownCache = await this.store.get(KEY_RATING_SHOWN, false) as boolean;
      this.hasDownlinkCache = await this.store.get(KEY_HAS_DOWNLINK, false) as boolean;
      this.firstDownlinkTsCache = await this.store.get(KEY_FIRST_DOWNLINK_TS, 0) as number;
      this.declinedAtCache = await this.store.get(KEY_DECLINED_AT, 0) as number;
      this.permissionHintShownCache = await this.store.get(KEY_PERMISSION_HINT_SHOWN, false) as boolean;
      this.gpsModeCache = await this.store.get(KEY_GPS_MODE, 0) as number;
      hilog.info(0x0001, TAG, `[CHECKPOINT] PreferencesRepository initialized (${this.cache.length} cameras)`);
      for (const c of this.cache) {
        hilog.info(0x0001, TAG,
          `[CHECKPOINT]   saved: name='${c.name}' addr=${c.address} keepAlive=${c.keepAlive}`);
      }
      // Signal readiness — MainPage may be waiting to read the persisted tab.
      this.ready = true;
      const resolvers = this.readyResolvers;
      this.readyResolvers = [];
      for (const r of resolvers) r();
    } catch (err) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] PreferencesRepository init ERROR: ${JSON.stringify(err)}`);
      // Even on failure, unblock waiters (they'll read the defaults).
      this.ready = true;
      const resolvers = this.readyResolvers;
      this.readyResolvers = [];
      for (const r of resolvers) r();
    }
  }

  loadSavedCamerasSync(): PairedCamera[] {
    return this.cache;
  }

  // ==================== 首次连接提示 (one-time hint) ====================

  wasConnectHintShownSync(): boolean {
    return this.connectHintShownCache;
  }

  saveConnectHintShown(): void {
    this.connectHintShownCache = true;
    this.putBool(KEY_CONNECT_HINT_SHOWN, true);
  }

  // ==================== 多设备连接提醒 (beyond-N-cameras warning) ====================

  wasMultiCamWarnedSync(): boolean {
    return this.multiCamWarnedCache;
  }

  saveMultiCamWarned(): void {
    this.multiCamWarnedCache = true;
    this.putBool(KEY_MULTI_CAM_WARNED, true);
  }

  // ==================== 评分弹窗 (rating prompt) ====================

  /** True once the user tapped 去评分 — permanent, never re-prompt (the market
   * enforces its own 1-year rate limit via error 1021500009, so no local
   * throttle beyond this "already went" flag is needed). */
  wasRatingShownSync(): boolean {
    return this.ratingShownCache;
  }

  saveRatingShown(): void {
    this.ratingShownCache = true;
    this.putBool(KEY_RATING_SHOWN, true);
  }

  /** True once any GEO write was acked (hard evidence the pairing worked). */
  hasDownlinkSync(): boolean {
    return this.hasDownlinkCache;
  }

  saveHasDownlink(): void {
    if (this.hasDownlinkCache) return; // latch — never write again
    this.hasDownlinkCache = true;
    this.putBool(KEY_HAS_DOWNLINK, true);
  }

  /** First GEO-ack timestamp, 0 until the first confirmed downlink. */
  getFirstDownlinkTsSync(): number {
    return this.firstDownlinkTsCache;
  }

  saveFirstDownlinkTsIfZero(now: number): void {
    if (this.firstDownlinkTsCache !== 0) return; // first wins — latch
    this.firstDownlinkTsCache = now;
    this.putNumber(KEY_FIRST_DOWNLINK_TS, now);
  }

  /** Last 谢绝/dismiss timestamp, 0 if the user never declined. */
  getDeclinedAtSync(): number {
    return this.declinedAtCache;
  }

  saveDeclinedAt(now: number): void {
    this.declinedAtCache = now;
    this.putNumber(KEY_DECLINED_AT, now);
  }

  // ==================== 定位权限说明 (location "always allow" hint) ====================

  /** True once the location "always allow" hint has been shown. */
  wasPermissionHintShownSync(): boolean {
    return this.permissionHintShownCache;
  }

  savePermissionHintShown(): void {
    this.permissionHintShownCache = true;
    this.putBool(KEY_PERMISSION_HINT_SHOWN, true);
  }

  // ==================== GPS 采样档位 ====================

  /** 0=precise (default), 1=power-saving. Cache-backed sync read. */
  getGpsModeSync(): number {
    return this.gpsModeCache;
  }

  setGpsMode(mode: number): void {
    this.gpsModeCache = mode;
    this.putNumber(KEY_GPS_MODE, mode);
  }

  // ==================== Tab 持久化 ====================

  loadLastTabIndexSync(): number {
    return this.lastTabIndexCache;
  }

  saveLastTabIndex(index: number): void {
    this.lastTabIndexCache = index;
    this.putNumber(KEY_LAST_TAB, index);
  }

  // ==================== 重置引导 (re-show one-time content) ====================

  /** Reset all "show once" flags so the first-connect hint, the multi-camera
   * warning, the rating decline cooldown and the location "always allow" hint
   * are shown again. Invoked from the 关于 sheet. Deliberately NOT reset:
   * `hasDownlink`/`first_downlink_ts` (evidence, not hints) and `rating_shown`
   * (the user already tapped 去评分 — permanent). */
  resetOnboarding(): void {
    this.connectHintShownCache = false;
    this.multiCamWarnedCache = false;
    this.declinedAtCache = 0;
    this.permissionHintShownCache = false;
    this.putBool(KEY_CONNECT_HINT_SHOWN, false);
    this.putBool(KEY_MULTI_CAM_WARNED, false);
    this.putNumber(KEY_DECLINED_AT, 0);
    this.putBool(KEY_PERMISSION_HINT_SHOWN, false);
    hilog.info(0x0001, TAG, '[CHECKPOINT] onboarding flags reset');
  }

  // ==================== 连接健康看板 (SLA timeline) ====================

  /** Per-camera SLA key — `sla_<cameraName>`; the camera name is a BLE broadcast
   * name (ASCII), so the namespaced key is collision-free against the flat keys. */
  private slaKey(name: string): string {
    return KEY_SLA_PREFIX + name;
  }

  /** Persist a camera's SLA snapshot (serialized by SlaTracker) through the
   * shared saveQueue so SLA writes interleave safely with camera writes. */
  saveSla(name: string, json: string): void {
    this.enqueueScalarWrite(async (): Promise<void> => {
      if (!this.store) {
        setTimeout(() => { this.saveSla(name, json); }, 1000);
        return;
      }
      try {
        await this.store.put(this.slaKey(name), json);
        await this.store.flush();
      } catch (err) {
        hilog.error(0x0001, TAG, `saveSla(${name}) ERROR: ${JSON.stringify(err)}`);
      }
    });
  }

  /** Read a camera's persisted SLA snapshot (async — the store is async). */
  async loadSla(name: string): Promise<string | null> {
    if (!this.store) return null;
    try {
      const json = await this.store.get(this.slaKey(name), '') as string;
      return json !== '' ? json : null;
    } catch (err) {
      hilog.error(0x0001, TAG, `loadSla(${name}) ERROR: ${JSON.stringify(err)}`);
      return null;
    }
  }

  /** Delete a camera's SLA timeline (on removeCamera). */
  removeSla(name: string): void {
    this.enqueueScalarWrite(async (): Promise<void> => {
      if (!this.store) {
        setTimeout(() => { this.removeSla(name); }, 1000);
        return;
      }
      try {
        await this.store.delete(this.slaKey(name));
        await this.store.flush();
      } catch (err) {
        hilog.error(0x0001, TAG, `removeSla(${name}) ERROR: ${JSON.stringify(err)}`);
      }
    });
  }

  /** Delete EVERY persisted SLA timeline (关于 → 删除连接健康度日志). Walks the
   * whole store and removes every sla_-prefixed key — including orphan keys of
   * cameras already removed, which a per-name sweep would miss. Serialized. */
  clearAllSla(): void {
    this.enqueueScalarWrite(async (): Promise<void> => {
      if (!this.store) {
        setTimeout(() => { this.clearAllSla(); }, 1000);
        return;
      }
      try {
        const all = await this.store.getAll() as Record<string, Object>;
        const keys: string[] = [];
        for (const k of Object.keys(all)) {
          if (k.startsWith('sla_')) keys.push(k);
        }
        for (const k of keys) {
          await this.store.delete(k);
        }
        await this.store.flush();
        hilog.info(0x0001, TAG, 'clearAllSla: removed ' + keys.length + ' key(s)');
      } catch (err) {
        hilog.error(0x0001, TAG, 'clearAllSla ERROR: ' + JSON.stringify(err));
      }
    });
  }

  /** Serialize a scalar put through the saveQueue — otherwise rapid calls
   * (e.g. fast tab switches) interleave put+flush and a stale value can land
   * last. */
  private enqueueScalarWrite(op: () => Promise<void>): void {
    const run = (): Promise<void> => op();
    this.saveQueue = this.saveQueue.then(run, run);
  }

  private putNumber(key: string, value: number): void {
    this.enqueueScalarWrite(async (): Promise<void> => {
      if (!this.store) {
        setTimeout(() => { this.putNumber(key, value); }, 1000);
        return;
      }
      try {
        await this.store.put(key, value);
        await this.store.flush();
      } catch (err) {
        hilog.error(0x0001, TAG, `putNumber(${key}) ERROR: ${JSON.stringify(err)}`);
      }
    });
  }

  private putBool(key: string, value: boolean): void {
    this.enqueueScalarWrite(async (): Promise<void> => {
      if (!this.store) {
        setTimeout(() => { this.putBool(key, value); }, 1000);
        return;
      }
      try {
        await this.store.put(key, value);
        await this.store.flush();
      } catch (err) {
        hilog.error(0x0001, TAG, `putBool(${key}) ERROR: ${JSON.stringify(err)}`);
      }
    });
  }

  /**
   * Controller name written to the camera (0x2002 ID characteristic) — the name
   * shown in the camera's paired-device list. Generated once per install as
   * "HarmoNiLink-XXXX" so multiple phones paired to the same camera are
   * distinguishable; persisted and reused forever after.
   */
  getOrCreateControllerName(): string {
    if (this.controllerNameCache) return this.controllerNameCache;
    let suffix = '';
    for (let i = 0; i < 4; i++) {
      suffix += SUFFIX_CHARS.charAt(Math.floor(Math.random() * SUFFIX_CHARS.length));
    }
    const name = `HarmoNiLink-${suffix}`;
    this.controllerNameCache = name;
    hilog.info(0x0001, TAG, `[CHECKPOINT] Generated controller name: ${name}`);
    this.saveControllerName(name); // persist async
    return name;
  }

  private async saveControllerName(name: string): Promise<void> {
    if (!this.store) {
      setTimeout(() => { this.saveControllerName(name); }, 1000);
      return;
    }
    try {
      await this.store.put(KEY_CONTROLLER_NAME, name);
      await this.store.flush();
      hilog.info(0x0001, TAG, `[CHECKPOINT] Controller name persisted: ${name}`);
    } catch (err) {
      hilog.error(0x0001, TAG, `saveControllerName ERROR: ${JSON.stringify(err)}`);
    }
  }

  /**
   * Save camera: update the in-memory cache immediately (with a CLONE so the
   * cache never shares mutable refs with callers), then persist a snapshot of
   * the whole cache asynchronously through the serialized write queue.
   */
  saveCameraSync(camera: PairedCamera): void {
    const clone = new PairedCamera(
      camera.name, camera.address, camera.addressType,
      camera.device, camera.nonce, camera.controllerName, camera.keepAlive
    );
    const idx = this.cache.findIndex((c) => c.name === clone.name);
    if (idx >= 0) {
      this.cache[idx] = clone;
    } else {
      this.cache.push(clone);
    }
    this.enqueueSnapshotWrite();
  }

  async saveCamera(camera: PairedCamera): Promise<void> {
    this.saveCameraSync(camera);
  }

  async removeCamera(name: string): Promise<void> {
    const filtered = this.cache.filter((c) => c.name !== name);
    if (filtered.length === this.cache.length) return;
    this.cache = filtered;
    this.enqueueSnapshotWrite();
    hilog.info(0x0001, TAG, `[CHECKPOINT] removeCamera: removed '${name}' (${filtered.length} remaining)`);
  }

  /** Runtime-only mutation of a camera's connection toggle. Deliberately
   * does NOT touch disk: connection intent must not survive an app restart
   * (killing the app ends the session; a fresh launch starts all-OFF). */
  setKeepAliveRuntime(name: string, on: boolean): void {
    const cam = this.cache.find((c) => c.name === name);
    if (cam) cam.keepAlive = on;
  }

  /** Queue a strictly-ordered snapshot write of the current cache. */
  private enqueueSnapshotWrite(): void {
    const run = (): Promise<void> => this.writeSnapshot();
    this.saveQueue = this.saveQueue.then(run, run);
  }

  private async writeSnapshot(): Promise<void> {
    if (!this.store) {
      // Store not initialized yet (very early mutation) — retry shortly.
      await new Promise<void>((resolve) => { setTimeout(resolve, 500); });
      return this.writeSnapshot();
    }
    try {
      // Strip the runtime keepAlive flag — it is session state, never disk.
      const persistable = this.cache.map((c) => new PairedCamera(
        c.name, c.address, c.addressType, c.device, c.nonce, c.controllerName
      ));
      const json = JSON.stringify(persistable);
      await this.store.put(KEY_CAMERAS, json);
      await this.store.flush();
      hilog.info(0x0001, TAG, `[CHECKPOINT] prefs snapshot persisted (${persistable.length} cameras)`);
    } catch (err) {
      hilog.error(0x0001, TAG, `writeSnapshot ERROR: ${JSON.stringify(err)}`);
    }
  }
}
