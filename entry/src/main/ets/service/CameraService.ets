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

// Multi-camera connection cap. 0 = UNLIMITED (default): HarmonyOS has no
// public API for the platform's GATT limit, and field-tested stability only
// covers 2 cameras — the UI warns (dismissable) beyond that instead of
// refusing. Set a positive number to hard-enforce a cap again.
const MAX_CONNECTIONS = 0;

// Connected-camera count considered field-tested; opening connection
// (threshold + 1) triggers the dismissable stability/battery warning.
const MULTI_CAM_WARN_THRESHOLD = 2;

// GPS phase stagger: with N cameras, space each camera's write by this many ms
// so they don't all grab the radio in the same millisecond (Phase 2 power/
// scheduling strategy). 200ms is comfortably below the 1500ms foreground tick.
const GPS_PHASE_STAGGER_MS = 200;

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
  private devicesChangedListeners: Array<() => void> = [];
  // Sessions keyed by camera name — multiple in Phase 1.
  private sessions: Map<string, CameraSession> = new Map();
  // Reconnect pool: cameras waiting for their BLE address to be found by ONE
  // shared scan (routed by manufacturerDevice), instead of one scan each.
  private reconnectWatchers: ReconnectWatch[] = [];
  // True while the ONE shared BLE scan is running. The scanner is a SINGLE-
  // listener model, so pairing scan and reconnect scan must NOT each call
  // scanner.startScan() (the second would replace the first's listener and
  // strand reconnect sessions). ensureScanRunning() is the sole caller.
  private scanRunning: boolean = false;

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
  // Generation guard for the async start()/sync stop() race: stop() bumps this
  // so an in-flight start() (getWantAgent/startBackgroundRunning are awaited)
  // can detect it landed after a stop request and immediately undo itself.
  private bgGeneration: number = 0;

  // GPS ticker — one interval + alternating TIME/GEO, fanned out to Ready sessions.
  private gpsTimer: number | null = null;
  private gpsStep: number = 0; // 0=TIME, 1=GEO — alternating

  // "保持连接" is a PER-CAMERA flag on PairedCamera (Phase 3). No global
  // toggle state lives here anymore — see isKeepAlive/setKeepAlive below.

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

  /** Subscribe to paired-device-list changes (pair saved / camera removed).
   * Fired so the Pairing page can re-render its 已配对 markers — a live prefs
   * read that ForEach only refreshes when its key changes. */
  onDevicesChanged(listener: () => void): () => void {
    this.devicesChangedListeners.push(listener);
    return () => {
      const idx = this.devicesChangedListeners.indexOf(listener);
      if (idx !== -1) this.devicesChangedListeners.splice(idx, 1);
    };
  }

  /** Notify subscribers that the paired-device set changed (save / remove). */
  notifyDevicesChanged(): void {
    for (let i = 0; i < this.devicesChangedListeners.length; i++) {
      this.devicesChangedListeners[i]();
    }
  }

  getOwner(): OperationOwner { return this.owner; }

  getAbilityContext(): common.UIAbilityContext | null { return this.abilityContext; }

  /** Per-install controller name shown in the camera's paired-device list. */
  getControllerName(): string {
    return this.prefs.getOrCreateControllerName();
  }

  setContext(ctx: common.UIAbilityContext): void {
    // Idempotent: EntryAbility.onCreate calls this early so prefs.init() can
    // finish before MainPage reads the persisted tab index (no flash-of-wrong-
    // tab). MainPage still calls it (to refresh abilityContext); only the FIRST
    // call triggers the one-time satellite subscribe + async prefs load.
    const first = this.abilityContext === null;
    this.abilityContext = ctx;
    if (!first) return;
    // Satellite subscription is INDEPENDENT of camera connection: the GNSS
    // satellite count is a device-level reading that must NOT reset to "--"
    // when all cameras drop. Subscribe once at startup, keep it alive.
    this.subscribeSatelliteStatus();
    this.prefs.init(ctx); // async init — loadSavedCamerasSync will return cache once ready
  }

  // ==================== 保持连接 (per-camera auto-reconnect, Phase 3) ====================

  /** Keep-alive flag of one paired camera (reads live from the prefs cache). */
  isKeepAlive(name: string): boolean {
    const cam = this.prefs.loadSavedCamerasSync().find((c: PairedCamera) => c.name === name);
    return cam !== undefined && cam.keepAlive;
  }

  /** Flip one camera's connection toggle (SESSION-RUNTIME state — never
   * persisted, so a fresh app launch always starts with every switch OFF);
   * turning it off stops that camera's pending reconnect. */
  setKeepAlive(name: string, on: boolean): void {
    this.prefs.setKeepAliveRuntime(name, on);
    hilog.info(0x0001, TAG, `[RECONNECT] keep-alive ${on ? 'on' : 'off'} for '${name}'`);
    if (!on) {
      const s = this.sessions.get(name);
      if (s) s.onKeepAliveDisabled();
    }
    // Turning ON creates reconnect intent — the ContinuousTask must start now
    // (before any camera is Ready), not only when the GPS ticker spins up.
    this.reconcileBackgroundTask();
  }

  /** True if the first-connect hint (camera "关闭时发送" + keep-alive) has never been shown. */
  wasConnectHintShown(): boolean {
    return this.prefs.wasConnectHintShownSync();
  }

  markConnectHintShown(): void {
    this.prefs.saveConnectHintShown();
  }

  /** True while the user has NOT dismissed the beyond-N-cameras warning. */
  wasMultiCamWarned(): boolean {
    return this.prefs.wasMultiCamWarnedSync();
  }

  markMultiCamWarned(): void {
    this.prefs.saveMultiCamWarned();
  }

  /** Number of cameras whose connection toggle is ON — INTENT, not link
   * state: a camera mid-connect counts too, so rapidly flipping several
   * switches cannot slip past the warning while nothing is Ready yet. */
  getKeepAliveCount(): number {
    return this.prefs.loadSavedCamerasSync().filter((c: PairedCamera) => c.keepAlive).length;
  }

  /** True when opening ANOTHER connection would go beyond the field-tested
   * count — the UI warns (dismissable) before connecting. Based on toggle
   * intent: the in-flight camera's own flag is persisted only inside
   * startPendingConnect(), so the count here is the OTHERS already ON. */
  shouldWarnMultiCam(): boolean {
    return this.getKeepAliveCount() >= MULTI_CAM_WARN_THRESHOLD && !this.wasMultiCamWarned();
  }

  // ==================== Tab 持久化 + 关于 ====================

  /** Last selected tab index, persisted so the app reopens on the same page. */
  loadLastTabIndex(): number {
    return this.prefs.loadLastTabIndexSync();
  }

  /** Resolves once prefs.init() has loaded persisted values — MainPage waits
   * on this before reading the tab index, so the first render is correct
   * (no flash of the wrong tab on slow disks / large camera lists). */
  whenPrefsReady(): Promise<void> {
    return this.prefs.whenReady();
  }

  saveLastTabIndex(index: number): void {
    this.prefs.saveLastTabIndex(index);
  }

  /** Reset the one-time hints so they show again (关于 → 重置引导). */
  resetOnboarding(): void {
    this.prefs.resetOnboarding();
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

  /**
   * True while the pairing tab holds the global radio mutex. This is the ONLY
   * real mutex: connection/reconnect operations may run on many sessions in
   * parallel, so they never take ownership — they only defer to pairing
   * (classic bonding needs the radio exclusively). The old 'connection' owner
   * could not express "two sessions connecting at once" and let an early
   * Ready release stragglers' fallbacks (P0-1).
   */
  isPairingActive(): boolean {
    return this.owner === 'pairing';
  }

  /**
   * True while the pairing tab is in the classic-BONDING phase — the ONLY
   * radio-exclusive window (classic BT discovery + pairDevice). The pairing
   * SCAN (withClassic=false) and BLE handshake run fine in parallel with
   * connection operations, so connection ops defer to BONDING, not to the
   * whole pairing flow (otherwise a pairing scan would needlessly lock the
   * Connection page).
   */
  isPairingBonding(): boolean {
    if (this.owner !== 'pairing') return false;
    for (const s of this.sessions.values()) {
      if (s.isPairModeSession() && s.getState() === ConnectionState.Bonding) return true;
    }
    return false;
  }

  // ==================== Scan (Pairing Page, shared) ====================

  startPairingScan(): boolean {
    if (!this.requestOwnership('pairing')) return false;
    hilog.info(0x0001, TAG, '[CHECKPOINT] startPairingScan() called');
    this.discoveredList = [];
    this.pairScanActive = true;
    this.broadcastSessionState('', ConnectionState.Scanning, '正在扫描设备…');
    this.ensureScanRunning();
    return true;
  }

  getDiscoveredCameras(): DiscoveredCamera[] {
    return this.discoveredList;
  }

  /** True while the pairing-page scan is actively running — lets PairingPage
   * re-sync its 蓝牙扫描 toggle when its component instance is recreated. */
  isPairScanning(): boolean {
    return this.pairScanActive;
  }

  /**
   * Stop the pairing tab's scan WITHOUT killing the shared reconnect scan:
   * if reconnect watchers still exist, the underlying BLE scan must keep
   * running for them (sessions must never call scanner.stopScan() directly —
   * that offs every listener, P0-2).
   */
  stopPairingScanOnly(): void {
    if (!this.pairScanActive) return;
    this.pairScanActive = false;
    this.ensureScanRunning();
  }

  stopPairingScan(): void {
    if (!this.pairScanActive) return; // handshake already in flight — mutex stays with pairing
    this.stopPairingScanOnly();
    if (this.owner === 'pairing') {
      this.releaseOwnership();
      this.broadcastSessionState('', ConnectionState.Idle, '扫描已停止');
    }
  }

  /**
   * Single scan-entry point. The BleScanner holds ONE listener, so a pairing
   * scan must never replace a reconnect scan's listener (or reconnect sessions
   * strand in Scanning forever). Start/stop the ONE scan based on whether ANY
   * consumer (pairing page or reconnect watchers) needs it, and route every
   * result to BOTH consumers.
   */
  private ensureScanRunning(): void {
    const needed = this.pairScanActive || this.reconnectWatchers.length > 0;
    if (needed && !this.scanRunning) {
      this.scanRunning = true;
      this.scanner.startScan((cameras: DiscoveredCamera[]) => {
        this.discoveredList = cameras;
        this.routeReconnect(cameras);
      }, false); // NO classic discovery — it starves connected cameras' GPS writes (P1-5)
    } else if (!needed && this.scanRunning) {
      this.scanRunning = false;
      this.scanner.stopScan();
    }
  }

  // ==================== Delegated per-camera operations ====================

  /** Pairing progress of the in-flight pairing session (pairing is serial).
   *  DEPRECATED for success detection — a previously-connected camera keeps
   *  its step=6 and would pollute the max. Use getPairingStepFor(name). */
  getPairingStep(): number {
    let step = 0;
    this.sessions.forEach((s: CameraSession) => {
      const ps = s.getPairingStep();
      if (ps > step) step = ps;
    });
    return step;
  }

  /** Pairing step of ONE camera's session (0 if none). Success detection must
   * be per-session: a sibling camera's step=6 must not fake a success for a
   * camera whose own bonding just failed. */
  getPairingStepFor(name: string): number {
    const s = this.sessions.get(name);
    return s !== undefined ? s.getPairingStep() : 0;
  }

  /** True if a session for this camera exists and is connected. */
  isCameraConnected(name: string): boolean {
    const s = this.sessions.get(name);
    return s !== undefined && s.isConnected();
  }

  /** True while this camera is connecting/pairing/reconnecting (not Idle). */
  isCameraBusy(name: string): boolean {
    const s = this.sessions.get(name);
    return s !== undefined && s.getState() !== ConnectionState.Idle;
  }

  /** True if this camera has a pending auto-reconnect backoff timer. The
   * timer (not an external reconcile) owns when its next attempt fires. */
  isCameraReconnectPending(name: string): boolean {
    const s = this.sessions.get(name);
    return s !== undefined && s.isReconnectScheduled();
  }

  /** Number of currently Ready (connected) cameras. */
  getConnectedCount(): number {
    return this.getReadySessions().length;
  }

  /** True if another camera can still be connected under the cap (0 = uncapped). */
  canConnectMore(): boolean {
    return MAX_CONNECTIONS <= 0 || this.getConnectedCount() < MAX_CONNECTIONS;
  }

  startReconnect(camera: PairedCamera): boolean {
    if (!this.canConnectMore()) {
      hilog.warn(0x0001, TAG,
        `[CONN] limit reached (${this.getConnectedCount()}/${MAX_CONNECTIONS}) — refused ${camera.name}`);
      return false;
    }
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
      // Scope to PAIRING sessions only — a parallel connection-page connect
      // (Connecting/Discovering/Pairing) must NOT be torn down by cancelling
      // the pairing tab's operation.
      if (!s.isPairModeSession()) return;
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
    }
    // The GPS ticker and the ContinuousTask have DIFFERENT lifecycles: the
    // ticker needs a Ready session to write to, but the ContinuousTask must
    // outlive it — a keep-alive camera in reconnect (backoff/scan/connect) has
    // no Ready session, yet needs the process kept alive or the reconnect
    // timer can never fire (suspended app → no reconnection, ever).
    this.reconcileBackgroundTask();
  }

  /** True while any camera has its connection toggle ON — the INTENT alone
   * warrants the ContinuousTask (see reconcileBackgroundTask). */
  hasKeepAliveIntent(): boolean {
    return this.prefs.loadSavedCamerasSync().some((c: PairedCamera) => c.keepAlive);
  }

  /** Start/stop the ContinuousTask to match current connection intent:
   * keep it while any camera is Ready (GPS writing) OR has keep-alive intent
   * (reconnecting in the background); stop it only when neither holds. */
  private reconcileBackgroundTask(): void {
    const need = this.getReadySessions().length > 0 || this.hasKeepAliveIntent();
    if (need) {
      this.startBackgroundTask();
    } else {
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
    // Idempotent retry: setContext() subscribes at startup, but location
    // permission may not be granted yet then (it's requested on first scan).
    // Re-attempt here (no-op if already subscribed).
    this.subscribeSatelliteStatus();
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
        this.staggeredWrite(ready[i], i, timePayload, true);
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
            this.staggeredWrite(stillReady[i], i, payload, false);
          }
        }).catch(() => {
          hilog.debug(0x0001, TAG, '[GPS] GEO skip — no location');
        });
      } catch (e) {
        hilog.debug(0x0001, TAG, '[GPS] GEO skip — exception');
      }
    }
  }

  /**
   * Fan a write out to one camera, staggered by its index so N cameras don't
   * all transmit in the same instant. Writes are self-guarding (BleClient
   * drops them if the link is gone), so a delayed write after a disconnect is
   * harmless.
   */
  private staggeredWrite(session: CameraSession, index: number, payload: Uint8Array, isTime: boolean): void {
    const delay = index * GPS_PHASE_STAGGER_MS;
    const doWrite = (): void => {
      if (isTime) { session.writeTime(payload); } else { session.writeGeo(payload); }
    };
    if (delay === 0) {
      doWrite();
    } else {
      setTimeout(doWrite, delay);
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
    // Remove the record FIRST, then abort the session: disconnect() broadcasts
    // an Idle event synchronously, and ConnectionPage's reconcile would see the
    // still-saved record + an Idle session and immediately RESTART the connect
    // the user just asked to delete (ghost reconnect race).
    await this.prefs.removeCamera(name);
    const s = this.sessions.get(name);
    if (s) {
      s.cancelReconnectTimer();
      // Kills the in-flight connect/pair (watchdog + owner + shared-scan watch
      // + GATT link) and sets Idle so the stale guard swallows any late BLE
      // callbacks — including a connect that succeeds after the delete.
      s.disconnect();
    }
    // Drop the session entirely: a re-pair of the same camera must start from
    // a fresh session, not inherit this one's leftovers.
    this.sessions.delete(name);
    this.refreshGps();
    // Pairing page must drop the deleted camera's 已配对 marker.
    this.notifyDevicesChanged();
  }

  // ==================== Lifecycle (App Background/Foreground) ====================

  onAppBackground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Background');
    this.isForeground = false;
    if (this.getReadySessions().length > 0) {
      this.stopGpsLoop();
      this.startGpsLoop(5000); // switch to slow background interval
    }
    // A keep-alive camera mid-reconnect has no Ready session — ensure the
    // ContinuousTask is up so the background reconnect survives suspension.
    this.reconcileBackgroundTask();
  }

  onAppForeground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Foreground');
    this.isForeground = true;
    if (this.getReadySessions().length > 0) {
      this.stopGpsLoop();
      this.startGpsLoop(); // restore default 1500ms interval
    }
    this.reconcileBackgroundTask();
  }

  // ==================== Background Task ====================

  private async startBackgroundTask(): Promise<void> {
    if (this.backgroundTaskStarted || !this.abilityContext) return;

    const ctx = this.abilityContext;
    const gen = this.bgGeneration; // this request's generation

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
      if (gen !== this.bgGeneration) return; // a stop() raced in — abandon
      try {
        await backgroundTaskManager.startBackgroundRunning(ctx,
          backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION |
          backgroundTaskManager.BackgroundMode.LOCATION, agent);
        if (gen !== this.bgGeneration) {
          // Start landed after a stop request — immediately undo it, else the
          // notification task hangs while every switch is off.
          hilog.info(0x0001, TAG, '[BG] ContinuousTask started after stop — undoing');
          try { backgroundTaskManager.stopBackgroundRunning(ctx); } catch (e) { /* best-effort */ }
          return;
        }
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
    this.bgGeneration++; // invalidate any in-flight start()
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
    this.ensureScanRunning();
  }

  unwatchReconnect(name: string): void {
    this.reconnectWatchers = this.reconnectWatchers.filter((w) => w.camera.name !== name);
    this.ensureScanRunning();
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
