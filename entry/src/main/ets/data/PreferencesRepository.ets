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
  // Serialized disk writes. The CACHE is the single source of truth: it is
  // updated synchronously on every mutation, and queued tasks merely snapshot
  // it to disk. This kills the old read-disk-modify-write race where a slow
  // async save could overwrite the cache (and disk) with a STALE snapshot —
  // e.g. reverting a fresh keepAlive=true to false and snapping the UI toggle
  // off while the link stayed up.
  private saveQueue: Promise<void> = Promise.resolve();

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
      hilog.info(0x0001, TAG, `[CHECKPOINT] PreferencesRepository initialized (${this.cache.length} cameras)`);
      for (const c of this.cache) {
        hilog.info(0x0001, TAG,
          `[CHECKPOINT]   saved: name='${c.name}' addr=${c.address} keepAlive=${c.keepAlive}`);
      }
    } catch (err) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] PreferencesRepository init ERROR: ${JSON.stringify(err)}`);
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
   * warning, etc. are shown again. Invoked from the 关于 sheet. */
  resetOnboarding(): void {
    this.connectHintShownCache = false;
    this.multiCamWarnedCache = false;
    this.putBool(KEY_CONNECT_HINT_SHOWN, false);
    this.putBool(KEY_MULTI_CAM_WARNED, false);
    hilog.info(0x0001, TAG, '[CHECKPOINT] onboarding flags reset');
  }

  private async putNumber(key: string, value: number): Promise<void> {
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
  }

  private async putBool(key: string, value: boolean): Promise<void> {
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
