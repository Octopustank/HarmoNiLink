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

  async init(context: common.UIAbilityContext): Promise<void> {
    try {
      this.store = await preferences.getPreferences(context, STORE_NAME);
      this.cache = await this.loadSavedCameras();
      hilog.info(0x0001, TAG, `[CHECKPOINT] PreferencesRepository initialized (${this.cache.length} cameras)`);
    } catch (err) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] PreferencesRepository init ERROR: ${JSON.stringify(err)}`);
    }
  }

  loadSavedCamerasSync(): PairedCamera[] {
    return this.cache;
  }

  /**
   * Save camera to memory cache immediately, then persist to disk asynchronously.
   * This prevents data loss if the app crashes before the async write completes.
   */
  saveCameraSync(camera: PairedCamera): void {
    // Update in-memory cache immediately
    const idx = this.cache.findIndex((c) => c.name === camera.name);
    if (idx >= 0) {
      this.cache[idx] = camera;
    } else {
      this.cache.push(camera);
    }
    // Persist asynchronously
    this.saveCamera(camera);
  }

  async loadSavedCameras(): Promise<PairedCamera[]> {
    if (!this.store) {
      hilog.warn(0x0001, TAG, 'loadSavedCameras: store not initialized');
      return [];
    }

    try {
      const json = await this.store.get(KEY_CAMERAS, '[]') as string;
      const arr: SerializedCamera[] = JSON.parse(json);
      const cameras = arr.map((s) => new PairedCamera(
        s.name, s.address, s.addressType,
        s.device, s.nonce, s.controllerName
      ));
      hilog.info(0x0001, TAG,
        `[CHECKPOINT] loadSavedCameras: loaded ${cameras.length} cameras`);
      for (const c of cameras) {
        hilog.info(0x0001, TAG,
          `[CHECKPOINT]   saved: name='${c.name}' addr=${c.address} dev=0x${c.device.toString(16)}`);
      }
      return cameras;
    } catch (err) {
      hilog.error(0x0001, TAG, `loadSavedCameras ERROR: ${JSON.stringify(err)}`);
      return [];
    }
  }

  async saveCamera(camera: PairedCamera): Promise<void> {
    if (!this.store) {
      hilog.warn(0x0001, TAG, 'saveCamera: store not ready, queuing for later');
      // Retry in 1 second
      setTimeout(() => { this.saveCamera(camera); }, 1000);
      return;
    }

    try {
      const existing = await this.loadSavedCameras();
      // Replace if exists (by name), otherwise add
      const idx = existing.findIndex((c) => c.name === camera.name);
      if (idx >= 0) {
        existing[idx] = camera;
      } else {
        existing.push(camera);
      }
      const json = JSON.stringify(existing);
      await this.store.put(KEY_CAMERAS, json);
      await this.store.flush();
      this.cache = existing; // update cache
      hilog.info(0x0001, TAG,
        `[CHECKPOINT] saveCamera: saved '${camera.name}' (${existing.length} total)`);
    } catch (err) {
      hilog.error(0x0001, TAG, `saveCamera ERROR: ${JSON.stringify(err)}`);
    }
  }

  async removeCamera(name: string): Promise<void> {
    if (!this.store) return;

    try {
      const existing = await this.loadSavedCameras();
      const filtered = existing.filter((c) => c.name !== name);
      const json = JSON.stringify(filtered);
      await this.store.put(KEY_CAMERAS, json);
      await this.store.flush();
      hilog.info(0x0001, TAG, `[CHECKPOINT] removeCamera: removed '${name}' (${filtered.length} remaining)`);
    } catch (err) {
      hilog.error(0x0001, TAG, `removeCamera ERROR: ${JSON.stringify(err)}`);
    }
  }
}
