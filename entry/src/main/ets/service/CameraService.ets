/**
 * CameraService.ets — Multi-camera connection Hub
 *
 * Phase 1: the Hub now holds MULTIPLE sessions (keyed by camera name) and
 * broadcasts per-session state as events. The single global `_state` mirror
 * from Phase 0 is gone — each CameraSession owns its own state and pushes
 * `CameraStateEvent { cameraName, state, message }` through the Hub.
 *
 * Shared resources stay here: scanner, prefs, pairing engine, satellite
 * subscription, GPS ticker, background task, ownership (tab-level mutex).
 *
 * [CHECKPOINT] Every state transition, handshake step, and error is logged via HiLog.
 * For debugging, use: hdc shell hilog -T HarmoNiLink
 *
 * Based on nsg/android/.../CameraConnectionService.kt
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { geoLocationManager } from '@kit.LocationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent, abilityAccessCtrl } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PairedCamera, NikonPairingEngine } from '../ble/protocol/NikonPairingEngine';
import { GeoPayloadGenerator, GpsPosition } from '../ble/protocol/GeoPayloadGenerator';
import { TimePayloadGenerator } from '../ble/protocol/TimePayloadGenerator';
import { GpsData } from './GpsData';
import { BleScanner, DiscoveredCamera } from '../ble/BleScanner';
import { PreferencesRepository } from '../data/PreferencesRepository';
import { CameraSession } from './CameraSession';

const TAG = 'HarmoNiLink-CameraService';

// User-grant permissions needed for scan/pair/connect. Requested in ONE batch
// (system queues the dialogs) on first user action, not at app startup.
const USER_GRANT_PERMISSIONS: string[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.DISCOVER_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION',
];
// Must be requested AFTER LOCATION is granted; failure is non-fatal.
const BACKGROUND_LOCATION_PERMISSION: string = 'ohos.permission.LOCATION_IN_BACKGROUND';

export enum ConnectionState {
  Idle = 'Idle',
  Scanning = 'Scanning',
  Connecting = 'Connecting',
  Discovering = 'Discovering',
  Pairing = 'Pairing',
  Bonding = 'Bonding',
  Ready = 'Ready',
  Error = 'Error',
}

/** A per-camera state change, broadcast to all listeners. */
export interface CameraStateEvent {
  /** '' for global (pairing-scan / ownership) events; otherwise the camera name. */
  cameraName: string;
  state: ConnectionState;
  message: string;
}

export type StateListener = (event: CameraStateEvent) => void;
export type OperationOwner = 'pairing' | 'connection' | 'none';

/** A camera awaiting reconnect on the shared scan (reconnectPool). */
interface ReconnectWatch {
  camera: PairedCamera;
  session: CameraSession;
}

export class CameraService {
  // ==== Public shared state ====

  // Subsystems — SHARED across sessions (exposed to CameraSession).
  scanner: BleScanner = new BleScanner();
  prefs: PreferencesRepository = new PreferencesRepository();
  pairingEngine: NikonPairingEngine = new NikonPairingEngine();

  // GPS shared state — UI reads this directly; the single GPS ticker below
  // fans out to all Ready sessions.
  gpsData: GpsData = new GpsData();
  // Real GNSS satellite count fed by Location Kit's satelliteStatusChange.
  lastSatelliteCount: number = -1;
  // Foreground/background flag — the GPS ticker picks the interval from it.
  isForeground: boolean = true;

  // ==== Private shared state ====

  private stateListeners: StateListener[] = [];
  // Sessions keyed by camera name — multiple in Phase 1.
  private sessions: Map<string, CameraSession> = new Map();
  // Reconnect pool: cameras waiting for their BLE address to be found by ONE
  // shared scan (routed by manufacturerDevice), instead of one scan each.
  private reconnectWatchers: ReconnectWatch[] = [];
  private reconnectScanActive: boolean = false;

  // Ownership — prevents cross-tab operation conflicts (Hub-level mutex).
  private owner: OperationOwner = 'none';

  // Discovered cameras (populated by scanner callback) — shared scan result.
  private discoveredList: DiscoveredCamera[] = [];
  // True while the pairing page's shared scan is active (stop/cancel guard).
  private pairScanActive: boolean = false;

  // Context (set from EntryAbility)
  private abilityContext: common.UIAbilityContext | null = null;

  // Permission state
  private permissionJustGranted: boolean = false;

  // Satellite subscription state — single location source (Hub-owned).
  private satelliteSubscribed: boolean = false;
  private satelliteStatusCb: ((status: geoLocationManager.SatelliteStatusInfo) => void) | null = null;

  // Background task state — one ContinuousTask per app.
  private backgroundTaskStarted: boolean = false;

  // GPS ticker — one interval + alternating TIME/GEO, fanned out to Ready sessions.
  private gpsTimer: number | null = null;
  private gpsStep: number = 0; // 0=TIME, 1=GEO — alternating

  // "保持连接" — auto-reconnect toggle (default off, GLOBAL — Phase 3 may split
  // per camera).
  private reconnectEnabled: boolean = false;

  // ==================== Public API ====================

  setStateListener(listener: StateListener): () => void {
    this.stateListeners.push(listener);
    // Return an unregister closure — pages MUST call it on aboutToDisappear,
    // otherwise listeners accumulate on every tab switch (leak + stale @State writes).
    return () => {
      const idx = this.stateListeners.indexOf(listener);
      if (idx !== -1) this.stateListeners.splice(idx, 1);
    };
  }

  getOwner(): OperationOwner { return this.owner; }

  getAbilityContext(): common.UIAbilityContext | null { return this.abilityContext; }

  /** Per-install controller name shown in the camera's paired-device list. */
  getControllerName(): string {
    return this.prefs.getOrCreateControllerName();
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.abilityContext = ctx;
    // Satellite subscription is INDEPENDENT of camera connection: the GNSS
    // satellite count is a device-level reading that must NOT reset to "--"
    // when all cameras drop. Subscribe once at startup, keep it alive.
    this.subscribeSatelliteStatus();
    this.prefs.init(ctx).then(() => {
      // Persisted values are ready — sync the in-memory "保持连接" state
      this.reconnectEnabled = this.prefs.loadReconnectEnabledSync();
      hilog.info(0x0001, TAG, `[RECONNECT] loaded from prefs: ${this.reconnectEnabled}`);
    }); // start async init — loadSavedCamerasSync will return cache once ready
  }

  // ==================== 保持连接 (auto-reconnect, global toggle) ====================

  isReconnectEnabled(): boolean { return this.reconnectEnabled; }

  setReconnectEnabled(enabled: boolean): void {
    this.reconnectEnabled = enabled;
    this.prefs.saveReconnectEnabled(enabled);
    hilog.info(0x0001, TAG, `[RECONNECT] keep-connected ${enabled ? 'enabled' : 'disabled'}`);
    if (!enabled) {
      // Cancel any pending auto-reconnect attempt on every session
      this.sessions.forEach((s: CameraSession) => { s.cancelReconnectTimer(); });
    }
  }

  /** True if the "保持连接" explanation dialog has never been shown. */
  wasReconnectPrompted(): boolean {
    return this.prefs.wasReconnectPromptedSync();
  }

  markReconnectPrompted(): void {
    this.prefs.saveReconnectPrompted();
  }

  /** True if the first-connect hint (camera "关闭时发送" + 保持连接) has never been shown. */
  wasConnectHintShown(): boolean {
    return this.prefs.wasConnectHintShownSync();
  }

  markConnectHintShown(): void {
    this.prefs.saveConnectHintShown();
  }

  // ==================== Permissions ====================

  async requestPermissionsIfNeeded(): Promise<boolean> {
    this.permissionJustGranted = false;
    const ctx = this.abilityContext;
    if (!ctx) return false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const tokenId = ctx.applicationInfo.accessTokenId;
      const check = atManager.checkAccessTokenSync as Function;

      const needed: string[] = [];
      for (let i = 0; i < USER_GRANT_PERMISSIONS.length; i++) {
        const permission = USER_GRANT_PERMISSIONS[i];
        if (check(tokenId, permission) !== 0) needed.push(permission);
      }
      if (needed.length === 0) return true;

      hilog.info(0x0001, TAG, `[PERM] requesting ${needed.length} permission(s): ${needed.join(', ')}`);
      const req = atManager.requestPermissionsFromUser as Function;
      const result = await req(ctx, needed) as Record<string, Object>;
      const authResults = result['authResults'] as number[];

      let allGranted: boolean = true;
      for (let i = 0; i < authResults.length; i++) {
        if (authResults[i] !== 0) allGranted = false;
      }
      hilog.info(0x0001, TAG, `[PERM] batch result: ${authResults.join(', ')} allGranted=${allGranted}`);

      this.permissionJustGranted = allGranted;
      return allGranted;
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] request failed: ${JSON.stringify(err)}`);
      return false;
    }
  }

  wasPermissionJustGranted(): boolean {
    return this.permissionJustGranted;
  }

  isBackgroundLocationGranted(): boolean {
    const ctx = this.abilityContext;
    if (!ctx) return false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const check = atManager.checkAccessTokenSync as Function;
      return check(ctx.applicationInfo.accessTokenId, BACKGROUND_LOCATION_PERMISSION) === 0;
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] background check error: ${JSON.stringify(err)}`);
      return false;
    }
  }

  openBackgroundLocationSetting(): void {
    const ctx = this.abilityContext;
    if (!ctx) return;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const req = atManager.requestPermissionOnSetting as Function;
      req(ctx, [BACKGROUND_LOCATION_PERMISSION]).then((statuses: number[]) => {
        hilog.info(0x0001, TAG, `[PERM] on-setting result: ${statuses.join(', ')}`);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0001, TAG, `[PERM] requestPermissionOnSetting failed: ${err.message}`);
      });
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] requestPermissionOnSetting exception: ${JSON.stringify(err)}`);
    }
  }

  // ==================== Ownership (Hub-level mutex) ====================

  requestOwnership(source: OperationOwner): boolean {
    if (this.owner === 'none') { this.owner = source; return true; }
    if (this.owner === source) { return true; } // already owned by same caller
    hilog.warn(0x0001, TAG, `[OWNER] request denied: ${source} (active: ${this.owner})`);
    return false;
  }

  releaseOwnership(): void {
    hilog.info(0x0001, TAG, `[OWNER] released: ${this.owner}`);
    this.owner = 'none';
    // Re-broadcast a global event so listeners refresh their ownership mirror.
    // The caller's setState usually fires BEFORE this (while owner is still the
    // old value) — without this the UI stays stuck thinking it still owns the tab.
    this.broadcastSessionState('', ConnectionState.Idle, '');
  }

  // ==================== Scan (Pairing Page, shared) ====================

  startPairingScan(): boolean {
    if (!this.requestOwnership('pairing')) return false;
    hilog.info(0x0001, TAG, '[CHECKPOINT] startPairingScan() called');
    this.discoveredList = [];
    this.pairScanActive = true;
    this.broadcastSessionState('', ConnectionState.Scanning, '正在扫描设备…');
    this.scanner.startScan((cameras: DiscoveredCamera[]) => {
      this.discoveredList = cameras;
    });
    return true;
  }

  getDiscoveredCameras(): DiscoveredCamera[] {
    return this.discoveredList;
  }

  stopPairingScan(): void {
    this.scanner.stopScan();
    if (this.pairScanActive && this.owner === 'pairing') {
      this.pairScanActive = false;
      this.releaseOwnership();
      this.broadcastSessionState('', ConnectionState.Idle, '扫描已停止');
    }
  }

  // ==================== Delegated per-camera operations ====================

  /** Pairing progress of the in-flight pairing session (pairing is serial). */
  getPairingStep(): number {
    let step = 0;
    this.sessions.forEach((s: CameraSession) => {
      const ps = s.getPairingStep();
      if (ps > step) step = ps;
    });
    return step;
  }

  /** True if a session for this camera exists and is connected. */
  isCameraConnected(name: string): boolean {
    const s = this.sessions.get(name);
    return s !== undefined && s.isConnected();
  }

  startReconnect(camera: PairedCamera): boolean {
    return this.getOrCreateSession(camera.name).startReconnect(camera);
  }

  /** Disconnect a specific camera, or (no arg) all connected cameras. */
  disconnect(name?: string): void {
    if (name) {
      const s = this.sessions.get(name);
      if (s) s.disconnect();
      return;
    }
    this.sessions.forEach((s: CameraSession) => {
      if (s.isConnected()) s.disconnect();
    });
  }

  cancelPairing(): void {
    this.sessions.forEach((s: CameraSession) => {
      const st = s.getState();
      if (st === ConnectionState.Connecting || st === ConnectionState.Discovering
        || st === ConnectionState.Pairing || st === ConnectionState.Bonding) {
        s.cancelPairing();
      }
    });
  }

  selectDiscoveredCamera(camera: DiscoveredCamera): void {
    this.getOrCreateSession(camera.deviceName).selectDiscoveredCamera(camera);
  }

  // ==================== GPS (single ticker, fan-out to Ready sessions) ====================

  /**
   * Reconcile the GPS ticker with the current Ready sessions: restart (fan out
   * to the remaining cameras) if any remain, else stop. Call after ONE camera
   * disconnects/links-out — a bare stopGpsLoop() would kill GPS for the OTHER
   * still-connected cameras.
   */
  refreshGps(): void {
    if (this.getReadySessions().length > 0) {
      // A Ready camera exists: keep the ticker running, but DON'T restart it.
      // Restarting resets the satellite count (stopGpsLoop sets it to -1) and
      // re-subscribes; getReadySessions() is dynamic, so the running ticker
      // already fans out to the changed set on its next beat.
      this.ensureGpsRunning();
    } else {
      this.stopGpsLoop();
      this.stopBackgroundTask();
    }
  }

  /** Start the ticker only if it isn't already running (no satellite reset). */
  private ensureGpsRunning(): void {
    if (this.gpsTimer !== null) return;
    this.startGpsLoop();
  }

  startGpsLoop(intervalMs: number = 1500): void {
    const interval = this.isForeground ? intervalMs : 5000;
    hilog.info(0x0001, TAG, `[GPS] startGpsLoop: interval=${interval}ms fg=${this.isForeground}`);
    this.stopGpsLoop();
    this.gpsStep = 0;
    // Send TIME immediately, then alternate TIME/GEO
    this.sendGpsTick();
    this.gpsTimer = setInterval(() => { this.sendGpsTick(); }, interval);
    this.startBackgroundTask();
  }

  /** Ready sessions — only those whose handshake finished (chars prepared).
   *  isConnected() alone is true mid-pairing (gattClient exists but TIME/GEO
   *  chars aren't ready), and fanning GPS writes into such a session crashes
   *  writeCharacteristicValue with a 401. */
  private getReadySessions(): CameraSession[] {
    const ready: CameraSession[] = [];
    this.sessions.forEach((s: CameraSession) => {
      if (s.getState() === ConnectionState.Ready) ready.push(s);
    });
    return ready;
  }

  private sendGpsTick(): void {
    const ready = this.getReadySessions();
    if (ready.length === 0) {
      this.stopGpsLoop();
      return;
    }
    if (this.gpsStep === 0) {
      const timePayload = TimePayloadGenerator.build();
      hilog.info(0x0001, TAG, `[GPS] TIME ${timePayload.length}B to ${ready.length} camera(s)`);
      for (let i = 0; i < ready.length; i++) {
        ready[i].writeTime(timePayload);
      }
      this.gpsStep = 1;
    } else {
      this.gpsStep = 0;
      // Check if location service is enabled
      try {
        const locEnabled = geoLocationManager.isLocationEnabled?.() ?? true;
        if (!locEnabled) {
          hilog.warn(0x0001, TAG, '[GPS] Location service disabled, skip GEO');
          return;
        }
      } catch (e) { /* proceed anyway */ }

      try {
        geoLocationManager.getCurrentLocation({
          priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
          timeoutMs: 5000
        }).then((pos) => {
          const stillReady = this.getReadySessions();
          if (stillReady.length === 0) return;
          // Update shared GPS state
          const lat = pos.latitude;
          const lon = pos.longitude;
          const alt = Math.round(pos.altitude);
          const sats = this.lastSatelliteCount;
          this.gpsData.hasFix = true;
          this.gpsData.latitude = lat;
          this.gpsData.longitude = lon;
          this.gpsData.altitude = alt;
          this.gpsData.satellites = sats;
          this.gpsData.lastUpdateTime = new Date().toLocaleTimeString();

          const gps: GpsPosition = {
            latitude: lat, longitude: lon, altitude: alt,
            satellites: sats >= 0 ? sats : 6, timestamp: new Date()
          };
          hilog.info(0x0001, TAG, `[GPS] GEO real lat=${lat.toFixed(6)} lon=${lon.toFixed(6)}`);
          const payload = GeoPayloadGenerator.buildReal(gps);
          for (let i = 0; i < stillReady.length; i++) {
            stillReady[i].writeGeo(payload);
          }
        }).catch(() => {
          hilog.debug(0x0001, TAG, '[GPS] GEO skip — no location');
        });
      } catch (e) {
        hilog.debug(0x0001, TAG, '[GPS] GEO skip — exception');
      }
    }
  }

  stopGpsLoop(): void {
    if (this.gpsTimer !== null) {
      clearInterval(this.gpsTimer);
      this.gpsTimer = null;
      hilog.info(0x0001, TAG, '[CHECKPOINT] GPS loop stopped');
    }
    // Satellite subscription is independent of the ticker — do NOT reset
    // lastSatelliteCount here, so the satellite count survives camera drops.
  }

  private subscribeSatelliteStatus(): void {
    if (this.satelliteSubscribed) return;
    try {
      this.satelliteStatusCb = (status: geoLocationManager.SatelliteStatusInfo) => {
        if (status.satellitesNumber >= 0) {
          this.lastSatelliteCount = status.satellitesNumber;
        }
      };
      geoLocationManager.on('satelliteStatusChange', this.satelliteStatusCb);
      this.satelliteSubscribed = true;
      hilog.info(0x0001, TAG, '[GPS] subscribed to satelliteStatusChange');
    } catch (err) {
      this.satelliteSubscribed = false;
      this.satelliteStatusCb = null;
      hilog.warn(0x0001, TAG, `[GPS] satelliteStatusChange subscribe failed: ${JSON.stringify(err)}`);
    }
  }

  // ==================== Persistence ====================

  async getSavedCameras(): Promise<PairedCamera[]> {
    return this.prefs.loadSavedCamerasSync();
  }

  /** Synchronous already-paired check — the pairing page disables the 配对
   *  button for these (re-pairing must go through remove + fresh scan). */
  isPairedCamera(name: string): boolean {
    return this.prefs.loadSavedCamerasSync().some((c: PairedCamera) => c.name === name);
  }

  async removeCamera(name: string): Promise<void> {
    await this.prefs.removeCamera(name);
  }

  // ==================== Lifecycle (App Background/Foreground) ====================

  onAppBackground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Background');
    this.isForeground = false;
    if (this.getReadySessions().length > 0) {
      this.stopGpsLoop();
      this.startGpsLoop(5000); // switch to slow background interval
    }
  }

  onAppForeground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Foreground');
    this.isForeground = true;
    if (this.getReadySessions().length > 0) {
      this.stopGpsLoop();
      this.startGpsLoop(); // restore default 1500ms interval
    }
  }

  // ==================== Background Task ====================

  private async startBackgroundTask(): Promise<void> {
    if (this.backgroundTaskStarted || !this.abilityContext) return;

    const ctx = this.abilityContext;

    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };

    try {
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      try {
        await backgroundTaskManager.startBackgroundRunning(ctx,
          backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION |
          backgroundTaskManager.BackgroundMode.LOCATION, agent);
        this.backgroundTaskStarted = true;
        hilog.info(0x0001, TAG, '[BG] ContinuousTask started (BLUETOOTH + LOCATION)');
      } catch (err) {
        hilog.warn(0x0001, TAG,
          `[BG] startBackgroundRunning fail: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
      }
    } catch (err) {
      hilog.warn(0x0001, TAG,
        `[BG] getWantAgent fail: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
    }
  }

  stopBackgroundTask(): void {
    if (!this.backgroundTaskStarted || !this.abilityContext) return;

    try {
      backgroundTaskManager.stopBackgroundRunning(this.abilityContext);
      this.backgroundTaskStarted = false;
      hilog.info(0x0001, TAG, '[BG] ContinuousTask stopped');
    } catch (err) {
      hilog.warn(0x0001, TAG,
        `[BG] stopBackgroundRunning error: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
    }
  }

  // ==================== State broadcast ====================

  /** Broadcast a per-camera (or global, name='') state change to all listeners. */
  broadcastSessionState(cameraName: string, state: ConnectionState, message: string): void {
    hilog.info(0x0001, TAG, `[CHECKPOINT] STATE: [${cameraName || '(global)'}] ${state} — ${message}`);
    for (let i = 0; i < this.stateListeners.length; i++) {
      this.stateListeners[i]({ cameraName, state, message });
    }
  }

  // ==================== Reconnect pool (shared scan) ====================

  /**
   * Register a camera waiting to be reconnected. One shared scan serves all
   * watchers (routed by manufacturerDevice), so N sleeping cameras open one
   * scan instead of N — and their callbacks can't overwrite each other.
   */
  watchReconnect(camera: PairedCamera, session: CameraSession): void {
    this.unwatchReconnect(camera.name); // dedupe by name
    this.reconnectWatchers.push({ camera, session });
    if (!this.reconnectScanActive) {
      this.reconnectScanActive = true;
      this.scanner.startScan((cameras: DiscoveredCamera[]) => {
        this.routeReconnect(cameras);
      }, false); // reconnect scan — never classic discovery (it starves GPS writes)
    }
  }

  unwatchReconnect(name: string): void {
    this.reconnectWatchers = this.reconnectWatchers.filter((w) => w.camera.name !== name);
    if (this.reconnectWatchers.length === 0 && this.reconnectScanActive) {
      this.reconnectScanActive = false;
      this.scanner.stopScan();
    }
  }

  /** Shared-scan callback: match each watcher by device ID (name fallback). */
  private routeReconnect(cameras: DiscoveredCamera[]): void {
    const matched: ReconnectWatch[] = [];
    for (const w of this.reconnectWatchers) {
      const devHit = cameras.find((c) =>
        c.manufacturerDevice !== undefined
          && (c.manufacturerDevice >>> 0) === (w.camera.device >>> 0));
      const found = devHit ?? cameras.find((c) => c.deviceName === w.camera.name);
      if (found) {
        matched.push(w);
        w.session.onReconnectFound(found, w.camera, devHit !== undefined);
      }
    }
    for (const m of matched) {
      this.unwatchReconnect(m.camera.name);
    }
  }

  // ==================== Session management ====================

  private getOrCreateSession(name: string): CameraSession {
    let s = this.sessions.get(name);
    if (!s) {
      s = new CameraSession(this);
      this.sessions.set(name, s);
    }
    return s;
  }
}

// Global singleton — shared across all pages
export const cameraService = new CameraService();
