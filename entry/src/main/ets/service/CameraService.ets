/**
 * CameraService.ets — Multi-camera connection Hub (coordinator)
 *
 * Phase-2 module split: the Hub now COORDINATES four focused subsystems and
 * no longer implements them inline —
 *   PermissionsGateway   — on-demand runtime permissions
 *   BackgroundTaskKeeper — ContinuousTask lifecycle + interrupt notices
 *   GpsDispatcher        — single GPS ticker fanned out to Ready sessions
 *   SlaHub               — per-camera connection-health trackers
 * — plus what is inherently Hub-shaped: the session registry, the shared BLE
 * scan (pairing + reconnect pool), the pairing radio mutex, state broadcast,
 * and the prefs facade the pages talk to.
 *
 * The Hub holds MULTIPLE sessions (keyed by camera name) and broadcasts
 * per-session state as events (`CameraStateEvent { cameraName, state,
 * message }`). CameraSession owns what is per-connection; shared resources
 * stay here (scanner, prefs, pairing engine).
 *
 * [CHECKPOINT] Every state transition, handshake step, and error is logged via HiLog.
 * For debugging, use: hdc shell hilog -T HarmoNiLink
 *
 * Based on nsg/android/.../CameraConnectionService.kt
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PairedCamera, NikonPairingEngine } from '../ble/protocol/NikonPairingEngine';
import { BleScanner, DiscoveredCamera } from '../ble/BleScanner';
import { PreferencesRepository } from '../data/PreferencesRepository';
import { SlaSev, SlaCell } from '../data/SlaTracker';
import { CameraSession } from './CameraSession';
import { ConnectionState, CameraStateEvent, StateListener, OperationOwner } from './ConnectionTypes';
import { PermissionsGateway } from './PermissionsGateway';
import { BackgroundTaskKeeper } from './BackgroundTaskKeeper';
import { GpsDispatcher, GpsMode, GpsModePreset, GPS_MODE_PRESETS, GpsWriteTarget } from './GpsDispatcher';
import { SlaHub } from './SlaHub';
import { GpsData } from './GpsData';

const TAG = 'HarmoNiLink-CameraService';

// Multi-camera connection cap. 0 = UNLIMITED (default): HarmonyOS has no
// public API for the platform's GATT limit, and field-tested stability only
// covers 2 cameras — the UI warns (dismissable) beyond that instead of
// refusing. Set a positive number to hard-enforce a cap again.
const MAX_CONNECTIONS = 0;

// Connected-camera count considered field-tested; opening connection
// (threshold + 1) triggers the dismissable stability/battery warning.
const MULTI_CAM_WARN_THRESHOLD = 2;

/** A camera awaiting reconnect on the shared scan (reconnectPool). */
interface ReconnectWatch {
  camera: PairedCamera;
  session: CameraSession;
}

export class CameraService {
  // ==== Subsystems — SHARED across sessions (exposed to CameraSession) ====

  scanner: BleScanner = new BleScanner();
  prefs: PreferencesRepository = new PreferencesRepository();
  pairingEngine: NikonPairingEngine = new NikonPairingEngine();

  private permissions: PermissionsGateway;
  private bgTask: BackgroundTaskKeeper;
  private gps: GpsDispatcher;
  private sla: SlaHub;

  // ==== Hub-owned state ====

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

  constructor() {
    this.permissions = new PermissionsGateway((): common.UIAbilityContext | null => this.abilityContext);
    this.bgTask = new BackgroundTaskKeeper(
      (): common.UIAbilityContext | null => this.abilityContext,
      (): number => this.getReadySessions().length,
      (): boolean => this.hasKeepAliveIntent());
    this.gps = new GpsDispatcher(
      (): GpsWriteTarget[] => this.getReadySessions(),
      (name: string): void => { this.slaOnSignal(name, SlaSev.YELLOW); },
      (ok: boolean): void => { this.sla.onGeoResult(ok); });
    this.sla = new SlaHub(this.prefs);
  }

  // ==== GPS shared-state outlets (UI reads these directly) ====

  get gpsData(): GpsData { return this.gps.gpsData; }
  get isForeground(): boolean { return this.gps.isForeground; }
  set isForeground(v: boolean) { this.gps.isForeground = v; }

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
    this.gps.subscribeSatelliteStatus();
    // ContinuousTask cancel/suspend listeners — once at startup. Without them,
    // a silent system cancel leaves the task flag set forever and the guard in
    // startTask() early-returns on every retry (deadlock).
    this.bgTask.registerListeners();
    this.prefs.init(ctx); // async init — loadSavedCamerasSync will return cache once ready
    this.applyPersistedGpsMode(); // GEO rail follows the persisted power mode once prefs land
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
    if (on) {
      // Toggle ON = a fresh user attempt: re-arm the "camera waiting for
      // another device" hint for this round (retries within the round stay silent).
      const s = this.sessions.get(name);
      if (s) s.resetPairTargetHint();
    }
    if (!on) {
      const s = this.sessions.get(name);
      if (s) s.onKeepAliveDisabled();
    }
    // Turning ON creates reconnect intent — the ContinuousTask must start now
    // (before any camera is Ready), not only when the GPS ticker spins up.
    this.reconcileBackgroundTask();
    // USER-INTENT gate for the GEO subscription: alive while any paired
    // camera's toggle is ON, unsubscribed when the last one goes off.
    this.gps.setGeoIntent(this.hasKeepAliveIntent());
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

  // ==================== 评分弹窗 (rating prompt) ====================

  /** True once a GEO write was acked — the hard-evidence gate for the rating
   * prompt (only prompt after the pairing has actually delivered value). */
  hasDownlink(): boolean {
    return this.prefs.hasDownlinkSync();
  }

  /** True once the user tapped 去评分 — permanent (the market enforces its own
   * 1-year rate limit via 1021500009, so "already went" is all we need). */
  wasRatingShown(): boolean {
    return this.prefs.wasRatingShownSync();
  }

  markRatingShown(): void {
    this.prefs.saveRatingShown();
  }

  /** First GEO-ack epoch-ms, 0 until the first confirmed downlink. */
  getFirstDownlinkTs(): number {
    return this.prefs.getFirstDownlinkTsSync();
  }

  /** How many system rating dialogs were actually shown (see
   * PreferencesRepository — rate/dismiss are indistinguishable). */
  getRatingAttempts(): number {
    return this.prefs.getRatingAttemptsSync();
  }

  /** Last actually-shown rating dialog epoch-ms, 0 if never. */
  getRatingLastTs(): number {
    return this.prefs.getRatingLastTsSync();
  }

  markRatingAttempt(now: number): void {
    this.prefs.saveRatingAttempt(now);
  }

  // ==================== 定位权限说明 (location "always allow" hint) ====================

  /** True once the location "always allow" hint has been shown. */
  wasPermissionHintShown(): boolean {
    return this.prefs.wasPermissionHintShownSync();
  }

  markPermissionHintShown(): void {
    this.prefs.savePermissionHintShown();
  }

  // ==================== Permissions (delegated) ====================

  async requestPermissionsIfNeeded(): Promise<boolean> {
    return this.permissions.requestPermissionsIfNeeded();
  }

  isBackgroundLocationGranted(): boolean {
    return this.permissions.isBackgroundLocationGranted();
  }

  openBackgroundLocationSetting(): void {
    this.permissions.openBackgroundLocationSetting();
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
   * disconnects/links-out — a bare stop would kill GPS for the OTHER
   * still-connected cameras.
   */
  refreshGps(): void {
    if (this.getReadySessions().length > 0) {
      // A Ready camera exists: keep the ticker running, but DON'T restart it.
      // Restarting resets the satellite count (stop sets it to -1) and
      // re-subscribes; getReadySessions() is dynamic, so the running ticker
      // already fans out to the changed set on its next beat.
      this.gps.ensureRunning();
      // 重连 ≠ 定位：push the cached latest fix over BLE immediately (zero
      // GNSS cost) — the app-resident subscription kept it fresh while the
      // link was down, so a reconnecting camera gets where the USER is now.
      this.gps.writeCachedGps();
    } else {
      this.gps.stop();
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

  // ==================== GPS 采样档位（移动 / 定点 / 宽松） ====================

  /** Index into GPS_MODE_PRESETS (persisted). */
  getGpsModeSync(): number {
    return this.prefs.getGpsModeSync();
  }

  /** Apply a new mode: persist, re-subscribe the GEO rail with the new
   *  LocationRequest, and widen/narrow the SLA geoHealth freshness window. */
  setGpsMode(mode: GpsMode): void {
    this.prefs.setGpsMode(mode);
    this.gps.setMode(mode);
    this.sla.setGeoIntervalMs(GPS_MODE_PRESETS[mode].maxGeoIntervalMs);
    hilog.info(0x0001, TAG, `[GPS] sampling mode applied: ${GPS_MODE_PRESETS[mode].label}`);
  }

  /** Called once prefs are ready: apply the persisted mode (dispatcher
   *  defaults to MOVING until then). */
  applyPersistedGpsMode(): void {
    this.prefs.whenReady().then((): void => {
      const mode: GpsMode = this.prefs.getGpsModeSync() as GpsMode;
      const preset: GpsModePreset = GPS_MODE_PRESETS[mode];
      if (preset === undefined) return; // corrupted persisted value — keep default
      this.gps.setMode(mode);
      this.sla.setGeoIntervalMs(preset.maxGeoIntervalMs);
      hilog.info(0x0001, TAG, `[GPS] persisted sampling mode applied: ${preset.label}`);
    });
  }

  private reconcileBackgroundTask(): void {
    this.bgTask.reconcile();
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
    // Drop the SLA timeline too — a re-added camera must not inherit stale
    // health history (and the 2h window won't linger on disk).
    this.sla.remove(name);
    this.refreshGps();
    // Removing a camera may end the last ON intent — re-evaluate the gate.
    this.gps.setGeoIntent(this.hasKeepAliveIntent());
    // Pairing page must drop the deleted camera's 已配对 marker.
    this.notifyDevicesChanged();
  }

  // ==================== SLA timeline (连接健康看板) ====================

  /** GREEN signal — a GEO write was confirmed (full GPS downlink = has fix). */
  slaOnDownlink(name: string): void {
    this.sla.onDownlink(name);
  }

  /** Activity marker — a TIME write was confirmed. */
  slaOnActivity(name: string): void {
    this.sla.onActivity(name);
  }

  /** YELLOW/RED signal — an anomaly/transition for this camera. */
  slaOnSignal(name: string, sev: number): void {
    this.sla.onSignal(name, sev);
  }

  /** Materialize a camera's SLA timeline for the UI. Frozen snapshot — the
   * caller copies it into @State BEFORE showing the sheet (do NOT call inside
   * a @Builder: the state listener re-runs it and shifts the 2h window). */
  getSlaTimeline(name: string): SlaCell[] {
    return this.sla.getTimeline(name);
  }

  /** Materialize AFTER the persisted load settles — the first info-sheet open
   * renders the real history instead of an empty bar (async-load race). */
  async getSlaTimelineLoaded(name: string): Promise<SlaCell[]> {
    return this.sla.getTimelineLoaded(name);
  }

  /** Clear every camera's persisted health timeline + in-memory trackers
   * (关于 → 删除连接健康度日志). Slots restart empty from the next signal. */
  clearAllSla(): void {
    this.sla.clearAll();
  }

  /** Unconditional flush of every camera's SLA — last line of defense against
   * an app kill (wired from onAppBackground + EntryAbility.onDestroy). */
  flushSlaAll(): void {
    this.sla.flushAll();
  }

  // ==================== Lifecycle (App Background/Foreground) ====================

  onAppBackground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Background');
    this.gps.isForeground = false;
    this.sla.flushAll(); // persist SLA before the process may be suspended
    if (this.getReadySessions().length > 0) {
      this.gps.stop();
      this.gps.start(5000); // switch to slow background interval
    }
    // A keep-alive camera mid-reconnect has no Ready session — ensure the
    // ContinuousTask is up so the background reconnect survives suspension.
    this.bgTask.reconcile();
  }

  onAppForeground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Foreground');
    this.gps.isForeground = true;
    if (this.getReadySessions().length > 0) {
      this.gps.stop();
      this.gps.start(); // restore default 1500ms interval
    }
    this.bgTask.inferSilentRevocation();
    this.bgTask.reconcile();
    this.bgTask.scheduleInterruptNotice((): boolean => this.gps.isForeground);
  }

  // ==================== State broadcast ====================

  /** Broadcast a per-camera (or global, name='') state change to all listeners. */
  broadcastSessionState(cameraName: string, state: ConnectionState, message: string): void {
    hilog.info(0x0001, TAG, `[CHECKPOINT] STATE: [${cameraName || '(global)'}] ${state} — ${message}`);
    // A camera reaching Ready means the link is restored — the keeper clears
    // the interrupt latch / pending notice so the NEXT revocation re-notifies.
    if (state === ConnectionState.Ready) {
      this.bgTask.onReadyLinkRestored();
    }
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
