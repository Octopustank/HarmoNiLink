/**
 * CameraService.ets — Core state machine for Nikon camera connection
 *
 * Manages the full lifecycle:
 *   1. BLE scan → select camera
 *   2. GATT connect → service discovery → subscribe
 *   3. 4-stage Blowfish pairing handshake
 *   4. pairDevice() for dual-mode bonding
 *   5. Ready state: GPS loop
 *   6. Reconnect flow for saved cameras
 *
 * [CHECKPOINT] Every state transition, handshake step, and error is logged via HiLog.
 * For debugging, use: hdc shell hilog -T HarmoNiLink
 *
 * Based on nsg/android/.../CameraConnectionService.kt
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ble, connection } from '@kit.ConnectivityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent, abilityAccessCtrl } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { promptAction } from '@kit.ArkUI';
import { PairedCamera, NikonPairingEngine } from '../ble/protocol/NikonPairingEngine';
import { PairingMessage } from '../ble/protocol/PairingMessage';
import { GeoPayloadGenerator, GpsPosition } from '../ble/protocol/GeoPayloadGenerator';
import { TimePayloadGenerator } from '../ble/protocol/TimePayloadGenerator';
import { GpsData } from './GpsData';
import { BleScanner, DiscoveredCamera } from '../ble/BleScanner';
import { BleClient } from '../ble/BleClient';
import {
  BleConnected, BleDisconnected, BleServicesDiscovered, BleMtuChanged,
  BlePairIndication, BleNot1Notification, BleWriteDone, BleError, BleEvent
} from '../ble/BleEvent';
import { PreferencesRepository } from '../data/PreferencesRepository';

const TAG = 'HarmoNiLink-CameraService';
const DEFAULT_CONTROLLER_NAME: string = 'HarmoNiLink';

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

export type StateListener = (state: ConnectionState, message: string) => void;
export type OperationOwner = 'pairing' | 'connection' | 'none';

export class CameraService {
  // Public state
  private stateListeners: StateListener[] = [];
  private _state: ConnectionState = ConnectionState.Idle;
  private _statusMessage: string = 'Ready.';

  // Subsystems
  private scanner: BleScanner = new BleScanner();
  private bleClient: BleClient = new BleClient();
  private pairingEngine: NikonPairingEngine = new NikonPairingEngine();
  private prefs: PreferencesRepository = new PreferencesRepository();

  // Pairing state
  private savedCamera: PairedCamera | null = null;
  private controllerName: string = DEFAULT_CONTROLLER_NAME;
  private currentStage1: PairingMessage | null = null;
  private pairingStep: number = 0; // 0=idle, 1=stage1sent, 2=stage3sent, 3=stage4got, 4=idwritten, 5=bonding, 6=ready
  private isPairMode: boolean = true; // true=NEW, false=RECONNECT
  private cameraSerial: string = '';
  // Classic discovery / bonding state
  private bondingDiscoveryActive: boolean = false;
  // True while waiting for the BLE disconnect event to start classic discovery —
  // older bodies (D5600) only become classic-discoverable once BLE is fully down.
  private pendingBondingDiscovery: boolean = false;
  // Registered classic-discovery/bond listeners — kept by reference so
  // finishBonding can unregister them (connection.on accumulates otherwise).
  private bondDiscoveryCb: ((data: Object) => void) | null = null;
  private bondStateCb: ((data: connection.BondStateParam) => void) | null = null;
  private cameraName: string = ''; // real camera name (e.g. Z_6_2_<serial> / D5600_<serial>), set during scan

  // GPS loop
  private gpsTimer: number | null = null;
  private backgroundTaskStarted: boolean = false;

  // Connect watchdog — aborts stalled pairing against unresponsive devices
  private connectTimeoutId: number | null = null;
  // True when the last permission batch was granted (for one-time background-location prompt)
  private permissionJustGranted: boolean = false;

  // "保持连接" — auto-reconnect toggle (default off). When off, link loss lands
  // in a terminal state and waits for manual action. User-initiated disconnect()
  // always stops reconnecting regardless of this flag.
  private reconnectEnabled: boolean = false;
  // Pending auto-reconnect timer — dedupes scheduleReconnect() calls
  private reconnectTimerId: number | null = null;

  // Context (set from EntryAbility)
  private abilityContext: common.UIAbilityContext | null = null;

  // Ownership — prevents cross-tab operation conflicts
  private owner: OperationOwner = 'none';

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

  getState(): ConnectionState {
    return this._state;
  }

  getStatusMessage(): string {
    return this._statusMessage;
  }

  getCameraSerial(): string {
    return this.cameraSerial;
  }

  /** Readable device name — BLE broadcast name, set on pair/reconnect. */
  getCameraName(): string {
    return this.cameraName;
  }

  /**
   * Per-install controller name shown in the camera's paired-device list.
   */
  getControllerName(): string {
    return this.prefs.getOrCreateControllerName();
  }

  getPairingStep(): number {
    return this.pairingStep;
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.abilityContext = ctx;
    this.prefs.init(ctx).then(() => {
      // Persisted values are ready — sync the in-memory "保持连接" state
      this.reconnectEnabled = this.prefs.loadReconnectEnabledSync();
      hilog.info(0x0001, TAG, `[RECONNECT] loaded from prefs: ${this.reconnectEnabled}`);
    }); // start async init — loadSavedCamerasSync will return cache once ready
  }

  getOwner(): OperationOwner { return this.owner; }

  // ==================== 保持连接 (auto-reconnect) ====================

  isReconnectEnabled(): boolean { return this.reconnectEnabled; }

  setReconnectEnabled(enabled: boolean): void {
    this.reconnectEnabled = enabled;
    this.prefs.saveReconnectEnabled(enabled);
    hilog.info(0x0001, TAG, `[RECONNECT] keep-connected ${enabled ? 'enabled' : 'disabled'}`);
    if (!enabled && this.reconnectTimerId !== null) {
      // Cancel any pending auto-reconnect attempt immediately
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = null;
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

  /**
   * Ensure all user-grant permissions needed for scan/pair/connect.
   * Requests the missing ones in a single batch (system queues the dialogs).
   * Call before startPairingScan()/startReconnect().
   *
   * NOTE: LOCATION_IN_BACKGROUND cannot be granted via a pop-up (system rule);
   * the UI shows a one-time prompt after first grant instead, guiding the user
   * to enable "always allow" in system settings if they want background GPS.
   */
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

  /**
   * True if the last requestPermissionsIfNeeded() call actually granted
   * (or re-granted) the core permissions — used to trigger the one-time
   * background-location prompt only on first grant.
   */
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

  /**
   * Open the system settings page for LOCATION_IN_BACKGROUND
   * (cannot be granted via pop-up; user must pick "always allow" manually).
   */
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

  /**
   * Request operation ownership. Returns true if granted.
   * If another operation is active, returns false (caller must handle).
   */
  requestOwnership(source: OperationOwner): boolean {
    if (this.owner === 'none') { this.owner = source; return true; }
    if (this.owner === source) { return true; } // already owned by same caller
    hilog.warn(0x0001, TAG, `[OWNER] request denied: ${source} (active: ${this.owner})`);
    return false;
  }

  private releaseOwnership(): void {
    hilog.info(0x0001, TAG, `[OWNER] released: ${this.owner}`);
    this.owner = 'none';
    // Re-broadcast current state so listeners refresh ownership-based UI
    for (let i = 0; i < this.stateListeners.length; i++) {
      this.stateListeners[i](this._state, this._statusMessage);
    }
  }

  // ==================== Scan (Pairing Page) ====================

  // Discovered cameras (populated by scanner callback)
  private discoveredList: DiscoveredCamera[] = [];

  startPairingScan(): boolean {
    if (!this.requestOwnership('pairing')) return false;
    hilog.info(0x0001, TAG, '[CHECKPOINT] startPairingScan() called');
    this.discoveredList = [];
    this.setState(ConnectionState.Scanning, '正在扫描设备…');
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
    if (this._state === ConnectionState.Scanning && this.owner === 'pairing') {
      this.releaseOwnership();
      this.setState(ConnectionState.Idle, '扫描已停止');
    }
  }

  /**
   * User-initiated cancel during pairing (connecting/discovering/pairing/bonding).
   * Fully resets BLE + classic discovery + ownership so the UI returns to idle.
   */
  cancelPairing(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] cancelPairing() called');
    this.scanner.stopScan();
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
    this.disconnect();
  }

  // ==================== Pair Flow (Pairing Page) ====================

  selectDiscoveredCamera(camera: DiscoveredCamera): void {
    if (this.owner !== 'pairing') {
      hilog.warn(0x0001, TAG, '[OWNER] selectDiscoveredCamera ignored — not pairing owner');
      return;
    }
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] selectDiscoveredCamera: name='${camera.deviceName}' id=${camera.deviceId}`);

    // Stop BLE scan only (no state change — avoids spurious Idle that resets PairingPage isPairing)
    this.scanner.stopScan();

    // Check if we have saved data for this camera — if so, proceed with pair mode anyway
    // (ownership is pairing; reconnect flow requires connection ownership)
    const saved = this.prefs.loadSavedCamerasSync();
    const matched = saved.find((c: PairedCamera) => c.name === camera.deviceName);
    if (matched) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] Camera already paired — re-pairing');
    }

    // New camera — pair mode
    this.cameraName = camera.deviceName;
    this.isPairMode = true;
    this.savedCamera = null;
    // Use the per-install controller name ("HarmoNiLink-XXXX") so the camera's
    // paired-device list distinguishes multiple phones running this app.
    // Already-paired cameras keep their saved controllerName on reconnect.
    this.controllerName = this.prefs.getOrCreateControllerName();

    hilog.info(0x0001, TAG,
      `[CHECKPOINT] Trying BLE connect to ${camera.deviceId}`);
    this.connectToDevice(camera.deviceId);
  }

  // ==================== Connect Flow (Connection Page) ====================

  startReconnect(camera: PairedCamera): boolean {
    if (!this.requestOwnership('connection')) return false;
    // Re-entry guard: a double-tap would otherwise open two GATT clients and
    // two scan sessions racing each other.
    if (this._state === ConnectionState.Scanning || this._state === ConnectionState.Connecting
      || this._state === ConnectionState.Discovering || this._state === ConnectionState.Pairing) {
      hilog.warn(0x0001, TAG, '[CHECKPOINT] startReconnect ignored — operation already in progress');
      return false;
    }
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] startReconnect: name='${camera.name}' addr=${camera.address}`);

    this.isPairMode = false;
    this.savedCamera = camera;
    this.controllerName = camera.controllerName;
    // Restore the broadcast name — serial fallback (non-ASCII on D-series
    // bodies) and the UI device-name display both rely on it.
    this.cameraName = camera.name;

    // For reconnect, the camera's BLE address may have changed.
    // Scan for current advertisement by name, fall back to saved address.
    this.setState(ConnectionState.Scanning, `正在搜索 ${camera.name}…`);
    this.scanner.startScan((cameras: DiscoveredCamera[]) => {
      // Reliable reconnect: match the STABLE device ID from manufacturer data
      // (companyID 0x0399). Nikon rotates its BLE address on restart, so the
      // saved address is stale after sleep; the device ID picks the camera's
      // CURRENT address. Name match is only a fallback (e.g. pairing-mode
      // camera that no longer advertises 0x0399).
      //
      // Both sides are normalized to unsigned 32-bit before comparing: the
      // manufacturer parse returns unsigned, but a legacy-persisted
      // camera.device may still be signed-negative for IDs >= 2^31. `>>> 0`
      // reconciles them regardless of how the saved value was stored.
      let foundDevMatch = false;
      const found = cameras.find((c) => {
        const devMatch = c.manufacturerDevice !== undefined
          && (c.manufacturerDevice >>> 0) === (camera.device >>> 0);
        if (devMatch || c.deviceName === camera.name) {
          foundDevMatch = devMatch;
          return true;
        }
        return false;
      });
      if (found) {
        this.scanner.stopScan();
        hilog.info(0x0001, TAG,
          `[CHECKPOINT] reconnect scan found: newAddr=${found.deviceId} savedAddr=${camera.address} devMatch=${foundDevMatch}`);
        // Update address
        const updated = new PairedCamera(
          camera.name, found.deviceId, camera.addressType,
          camera.device, camera.nonce, camera.controllerName
        );
        this.savedCamera = updated;
        this.prefs.saveCameraSync(updated);
        this.connectToDevice(found.deviceId);
      }
    });

    // Timeout: fall back to the saved address after 10 seconds. This is NOT
    // just a last-ditch fallback — connecting to the (possibly stale) address
    // is a deliberate "poke" that wakes a sleeping camera. Once woken, the
    // camera re-advertises a fresh address that the next scan picks up
    // (observed in logs: poke -> disconnect -> fresh scan -> reconnect).
    setTimeout(() => {
      if (this._state === ConnectionState.Scanning && this.owner === 'connection') {
        hilog.info(0x0001, TAG, '[CHECKPOINT] reconnect scan timeout, using saved address');
        this.scanner.stopScan();
        this.connectToDevice(camera.address);
      }
    }, 10000);
    return true;
  }

  // ==================== Disconnect ====================

  disconnect(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] disconnect() called');
    this.stopGpsLoop();
    this.stopBackgroundTask();
    this.clearConnectTimeout();
    // Release ownership BEFORE tearing down BLE: bleClient.disconnect() emits
    // BleDisconnected synchronously, which must hit the stale guard instead of
    // triggering auto-reconnect for a user-initiated disconnect.
    this.releaseOwnership();
    // Cancel any bonding in flight — otherwise a late BONDED event (or the user
    // confirming a pending system dialog) could finish a pairing that was
    // cancelled, producing a ghost "已连接" with no connection.
    this.bondingDiscoveryActive = false;
    this.pendingBondingDiscovery = false;
    this.unregisterBondListeners();
    this.bleClient.disconnect();
    this.pairingStep = 0;
    this.currentStage1 = null;
    this.cameraSerial = '';
    this.cameraName = '';
    this.scanner.stopScan();
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
    this.setState(ConnectionState.Idle, '已断开');
  }

  // ==================== GPS ====================

  // GPS state — shared with UI via @Observed
  gpsData: GpsData = new GpsData();
  private gpsStep: number = 0; // 0=TIME, 1=GEO — alternating
  private isForeground: boolean = true;
  private reconnectRetries: number = 0; // backoff counter
  // True once a [ROOT] link-death cause (watchdog / write-*) has been logged
  // for the current link. Suppresses the nested "cause=disconnected" marker
  // that the teardown disconnect() emits right after the root cause.
  private linkLostRootMarked: boolean = false;

  // Real GNSS satellite count fed by Location Kit's satelliteStatusChange
  // event. -1 = "unknown" (no status event yet / GNSS unsupported / missing
  // permission). UI shows "--" for unknown; the wire payload falls back to 6
  // (a valid protocol value) only when unknown, else uses the real clamped value.
  private lastSatelliteCount: number = -1;
  private satelliteSubscribed: boolean = false;
  private satelliteStatusCb: ((status: geoLocationManager.SatelliteStatusInfo) => void) | null = null;

  startGpsLoop(intervalMs: number = 1500): void {
    const interval = this.isForeground ? intervalMs : 5000;
    hilog.info(0x0001, TAG, `[GPS] startGpsLoop: interval=${interval}ms fg=${this.isForeground}`);
    this.stopGpsLoop();
    this.subscribeSatelliteStatus();
    this.gpsStep = 0;
    // Send TIME immediately, then alternate TIME/GEO
    this.sendGpsTick();
    this.gpsTimer = setInterval(() => { this.sendGpsTick(); }, interval);
    this.startBackgroundTask();
  }

  private sendGpsTick(): void {
    if (!this.bleClient.isConnected()) {
      this.stopGpsLoop();
      return;
    }
    if (this.gpsStep === 0) {
      const timePayload = TimePayloadGenerator.build();
      hilog.info(0x0001, TAG, `[GPS] TIME ${timePayload.length}B`);
      this.bleClient.writeTime(timePayload);
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
          if (!this.bleClient.isConnected()) return;
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
            // Wire payload needs a value in the protocol range 0-100; use 6 as a
            // placeholder only when the real count is still unknown (-1). Never
            // fabricate a "normal-looking" value for the UI — that stays raw
            // (unknown → "--") so the display never lies.
            satellites: sats >= 0 ? sats : 6, timestamp: new Date()
          };
          hilog.info(0x0001, TAG, `[GPS] GEO real lat=${lat.toFixed(6)} lon=${lon.toFixed(6)}`);
          this.bleClient.writeGeo(GeoPayloadGenerator.buildReal(gps));
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
    this.unsubscribeSatelliteStatus();
    // Reset to "unknown" so the next connection does NOT briefly show the
    // previous session's stale satellite count before the first fix.
    this.lastSatelliteCount = -1;
    this.gpsData.satellites = -1;
  }

  /**
   * Subscribe to Location Kit's satelliteStatusChange event so the UI shows
   * the REAL GNSS satellite count instead of a hardcoded value. Non-fatal:
   * any failure (GNSS unsupported, permission missing) leaves
   * lastSatelliteCount at -1 (unknown). The 6 fallback only kicks in at
   * SEND time (see getCurrentLocation's payload build), never in the UI.
   */
  private subscribeSatelliteStatus(): void {
    if (this.satelliteSubscribed) return;
    try {
      // On devices without GNSS capability the on() call throws — the catch
      // leaves lastSatelliteCount at -1 (unknown), so no pre-check is needed.
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

  private unsubscribeSatelliteStatus(): void {
    const cb = this.satelliteStatusCb;
    if (!this.satelliteSubscribed || cb === null) return;
    try {
      geoLocationManager.off('satelliteStatusChange', cb);
    } catch (err) {
      hilog.warn(0x0001, TAG, `[GPS] satelliteStatusChange unsubscribe failed: ${JSON.stringify(err)}`);
    }
    this.satelliteStatusCb = null;
    this.satelliteSubscribed = false;
  }

  // ==================== Persistence ====================

  async getSavedCameras(): Promise<PairedCamera[]> {
    return this.prefs.loadSavedCamerasSync();
  }

  async removeCamera(name: string): Promise<void> {
    await this.prefs.removeCamera(name);
  }

  // ==================== Private ====================

  private connectToDevice(deviceId: string): void {
    this.setState(ConnectionState.Connecting, `正在连接 ${deviceId}…`);
    this.pairingStep = 0;
    this.currentStage1 = null;

    // Watchdog: if the device never responds (non-Nikon device, out of range),
    // abort instead of hanging forever. Cancelled on terminal states.
    // 60s: a sleeping camera can take ~30s just to establish the connection
    // (per the M5Stack reference), then MTU (up to 5s) + service-discovery
    // retries — 35s could kill a legitimate slow wake-up reconnect.
    this.clearConnectTimeout();
    this.connectTimeoutId = setTimeout(() => {
      if (this._state === ConnectionState.Ready || this._state === ConnectionState.Idle
        || this._state === ConnectionState.Error || this._state === ConnectionState.Bonding) {
        return; // already settled — nothing to abort
      }
      hilog.warn(0x0001, TAG, '[CHECKPOINT] Connect watchdog fired (60s) — aborting stalled pairing');
      this.linkLostRootMarked = true;
      hilog.warn(0x0001, TAG, '[CHECKPOINT] LINK LOST [ROOT] cause=watchdog');
      this.bleClient.disconnect();
      this.scanner.stopScan();
      try { connection.stopBluetoothDiscovery(); } catch (e) {}
      // Route through the unified recovery path instead of dying on Error —
      // auto-reconnect keeps trying while the camera is unavailable.
      this.handleLinkLost();
    }, 60000);

    this.bleClient.connect(deviceId, (event: BleEvent) => {
      this.handleBleEvent(event);
    });
  }

  private clearConnectTimeout(): void {
    if (this.connectTimeoutId !== null) {
      clearTimeout(this.connectTimeoutId);
      this.connectTimeoutId = null;
    }
  }

  private handleBleEvent(event: BleEvent): void {
    // === Stale event guard ===
    // All BLE events require active ownership. Without it, events are stale
    // callbacks from a disconnected gattClient.
    if (this.owner === 'none') {
      if (event instanceof BleError) {
        hilog.debug(0x0001, TAG, `[CHECKPOINT] BLE Error (stale, ignored): ${event.message}`);
      }
      return;
    }

    if (event instanceof BleConnected) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] BLE Connected');
      this.reconnectRetries = 0; // reset backoff on success
      this.linkLostRootMarked = false; // fresh link — clear root-cause marker
      this.setState(ConnectionState.Discovering, '正在发现服务…');
    } else if (event instanceof BleServicesDiscovered) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] Services Discovered');
      if (this.pairingStep === 0) {
        this.pairingStep = 1;
        this.bleClient.prepare(() => {
          hilog.info(0x0001, TAG, '[CHECKPOINT] prepare done, beginning handshake');
          this.setState(ConnectionState.Pairing, '正在进行配对…');
          // Delay to let BLE stack settle after prepare
          setTimeout(() => { this.beginHandshake(); }, 500);
        });
      } else {
        hilog.info(0x0001, TAG, `[CHECKPOINT] ServicesDiscovered ignored (pairingStep=${this.pairingStep})`);
      }
    } else if (event instanceof BleMtuChanged) {
      hilog.info(0x0001, TAG, `[CHECKPOINT] MTU=${event.mtu}`);
    } else if (event instanceof BlePairIndication) {
      this.handlePairIndication(event.data);
    } else if (event instanceof BleNot1Notification) {
      this.handleNot1Notification(event.data);
    } else if (event instanceof BleWriteDone) {
      this.handleWriteDone(event.uuid);
    } else if (event instanceof BleDisconnected) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] BLE Disconnected');
      if (this._state === ConnectionState.Bonding && this.pendingBondingDiscovery) {
        // BLE link fully down — camera should now be classic-discoverable.
        // Bonding path handles the rest; don't route to handleLinkLost.
        this.pendingBondingDiscovery = false;
        hilog.info(0x0001, TAG, '[CHECKPOINT] BLE fully down — starting classic discovery');
        this.startClassicDiscoveryForBonding();
        return;
      }
      // Only log the root cause once: when the disconnect comes from the BLE
      // stack itself (camera-side drop / link loss). A disconnect that follows
      // a watchdog kill or write error is a NESTED teardown whose root cause
      // was already logged with a [ROOT] marker — don't re-attribute it.
      if (!this.linkLostRootMarked) {
        hilog.warn(0x0001, TAG, '[CHECKPOINT] LINK LOST cause=disconnected');
      }
      this.handleLinkLost();
    } else if (event instanceof BleError) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] BLE Error: ${event.message}`);
      // Link-death attribution: three-way split so a slow-waking camera's
      // death can be traced to exactly one cause. The P1 watchdog relaxation
      // (35s -> 60s) may shift it from watchdog to write timeout (3 x 10s) —
      // this split makes that shift visible in logs.
      let cause: string;
      if (event.message.startsWith('Write timeout')) {
        cause = 'write-timeout';
      } else if (event.message.startsWith('Write ')) {
        cause = 'write-error';
      } else {
        cause = 'ble-error';
      }
      this.linkLostRootMarked = true;
      hilog.warn(0x0001, TAG, `[CHECKPOINT] LINK LOST [ROOT] cause=${cause}`);
      // Pair-target hint: reaching Pairing means connect + service discovery
      // both succeeded — a PAIR write failure at that point almost always
      // means the camera is not treating this link as a pairing target (it is
      // waiting for another paired device), not a link problem.
      if (this._state === ConnectionState.Pairing && event.message.startsWith('Write')) {
        this.maybeShowPairTargetHint();
      }
      // Link-loss signal, not a terminal state: tear down and let
      // handleLinkLost decide between auto-reconnect and settling.
      this.bleClient.disconnect();
      this.scanner.stopScan();
      try { connection.stopBluetoothDiscovery(); } catch (e) {}
      this.handleLinkLost();
    }
  }

  /**
   * "Camera is waiting for another paired device" hint. Shown at most once
   * per 60s — the reconnect loop fails every ~10s, so without throttling the
   * dialog would spam.
   */
  private lastPairTargetHintAt: number = 0;

  private maybeShowPairTargetHint(): void {
    if (Date.now() - this.lastPairTargetHintAt < 60000) return;
    this.lastPairTargetHintAt = Date.now();
    hilog.warn(0x0001, TAG, '[CHECKPOINT] Camera may be waiting for another device — showing hint');
    promptAction.showDialog({
      title: '连接提示',
      message: `相机端可能未选择本设备。请在相机【已配对设备】里，将当前设备切换为「${this.controllerName || 'HarmoNiLink'}」后重试。`,
      buttons: [{ text: '知道了', color: '#0A59F7' }]
    }).catch((e: BusinessError) => {
      hilog.warn(0x0001, TAG, `[CHECKPOINT] Hint dialog failed: ${e.message}`);
    });
  }

  // ==================== Handshake Logic ====================

  private beginHandshake(): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] beginHandshake: mode=${this.isPairMode ? 'PAIR' : 'RECONNECT'}`);

    this.currentStage1 = this.pairingEngine.createStage1(
      this.isPairMode ? null : this.savedCamera
    );
    this.advancePairingStep(1);

    const data = this.currentStage1.encode();
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] Sending stage 1: ${this.currentStage1.toString()}`);
    this.bleClient.writePairMessage(data);
  }

  private handlePairIndication(data: Uint8Array): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] handlePairIndication: step=${this.pairingStep} dataLen=${data.length}`);

    if (data.length !== 17) {
      hilog.warn(0x0001, TAG,
        `[CHECKPOINT] Unexpected PAIR data length: ${data.length} (expected 17)`);
      return;
    }

    const msg = PairingMessage.decode(data);
    hilog.info(0x0001, TAG, `[CHECKPOINT] Decoded: stage=${msg.stage} ${msg.toString()}`);

    if (this.pairingStep === 1 && msg.stage === 0x02) {
      // Received stage 2 — verify and build stage 3
      const stage1 = this.currentStage1;
      if (!stage1) {
        hilog.error(0x0001, TAG, '[CHECKPOINT] No stage1 data! Aborting.');
        return;
      }

      const stage3 = this.pairingEngine.verifyStage2AndBuildStage3(stage1, msg);
      if (!stage3) {
        hilog.error(0x0001, TAG, '[CHECKPOINT] Salt verification FAILED — handshake aborted');
        // Release ownership + drop BLE before showing Error, otherwise the
        // pairing tab stays stuck owning a live link with no recovery path.
        this.releaseOwnership();
        this.bleClient.disconnect();
        this.pairingStep = 0;
        this.currentStage1 = null;
        this.setState(ConnectionState.Error, '配对失败：安全验证不匹配');
        return;
      }

      hilog.info(0x0001, TAG, `[CHECKPOINT] Sending stage 3: ${stage3.toString()}`);
      this.bleClient.writePairMessage(stage3.encode());
      this.advancePairingStep(2);
    } else if (this.pairingStep === 2 && msg.stage === 0x04) {
      // Received stage 4 — extract serial
      const serial = this.pairingEngine.extractSerial(msg);
      // D-series bodies put binary data in the serial field (D5600 → garbled
      // bytes like 'éKºóû§q'); fall back to the readable BLE broadcast name.
      this.cameraSerial = serial.length > 0 && /^[\x20-\x7E]*$/.test(serial) ? serial : this.cameraName;
      this.advancePairingStep(3);

      hilog.info(0x0001, TAG,
        `[CHECKPOINT] Stage 4 received. Camera serial: '${serial}'. Waiting for NOT1 01 00...`);

      // Fallback: write ID after 3 seconds if no NOT1 notification
      setTimeout(() => {
        if (this.pairingStep === 3) {
          hilog.info(0x0001, TAG, '[CHECKPOINT] No NOT1 after 3s — writing ID anyway');
          this.writeControllerId();
        }
      }, 3000);
    } else {
      hilog.warn(0x0001, TAG,
        `[CHECKPOINT] Unexpected PAIR stage=${msg.stage} at pairing step=${this.pairingStep}`);
    }
  }

  private handleNot1Notification(data: Uint8Array): void {
    const hex = Array.from(data).map(b => b.toString(16).padStart(2, '0')).join(' ');
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] NOT1: len=${data.length} data=[${hex}]`);

    const isSuccess = data.length >= 2 && data[0] === 0x01 && data[1] === 0x00;
    if (isSuccess) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] NOT1: success notification (01 00) received!');
      if (this.pairingStep === 3) {
        this.writeControllerId();
      }
    } else {
      hilog.info(0x0001, TAG, `[CHECKPOINT] NOT1: non-success notification`);
    }
  }

  private writeControllerId(): void {
    if (this.pairingStep >= 4) {
      hilog.info(0x0001, TAG, 'writeControllerId: already done, skipping');
      return;
    }
    this.advancePairingStep(4);

    // Write 32-byte ASCII name (zero-padded)
    const nameBytes = new Uint8Array(32);
    for (let i = 0; i < Math.min(this.controllerName.length, 32); i++) {
      nameBytes[i] = this.controllerName.charCodeAt(i);
    }

    hilog.info(0x0001, TAG,
      `[CHECKPOINT] writeControllerId: '${this.controllerName}' (32 bytes, zero-padded)`);
    this.bleClient.writeId(nameBytes);

    // Fallback: proceed to bonding after 3 seconds if no write callback
    setTimeout(() => {
      if (this.pairingStep === 4) {
        hilog.info(0x0001, TAG, '[CHECKPOINT] ID write timeout — proceeding to bonding');
        this.advancePairingStep(5);
        this.checkBondedAndFinish();
      }
    }, 3000);
  }

  private handleWriteDone(uuid: string): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] handleWriteDone: uuid=${uuid} step=${this.pairingStep}`);

    const idUuid = '00002002-3DD4-4255-8D62-6DC7B9BD5561';
    const geoUuid = '00002007-3DD4-4255-8D62-6DC7B9BD5561';

    if (uuid.toLowerCase() === idUuid.toLowerCase() && this.pairingStep === 4) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] ID write confirmed — proceeding to bonding');
      this.advancePairingStep(5);
      this.checkBondedAndFinish();
    } else if (uuid.toLowerCase() === geoUuid.toLowerCase()) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] GEO write confirmed');
    }
  }

  private checkBondedAndFinish(): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] checkBondedAndFinish: mode=${this.isPairMode ? 'PAIR' : 'RECONNECT'}`);

    if (!this.isPairMode) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] Reconnect mode — skipping bonding');
      this.onBonded();
      return;
    }

    // PAIR mode: save camera data first
    if (this.currentStage1) {
      const deviceId = this.bleClient.getDeviceId();
      const camera = new PairedCamera(
        this.cameraName || deviceId, deviceId, 1,
        this.currentStage1.device, this.currentStage1.nonce, this.controllerName
      );
      this.prefs.saveCameraSync(camera);
      this.savedCamera = camera;
      hilog.info(0x0001, TAG,
        `[CHECKPOINT] Camera saved: ${camera.name}`);
    }

    // Disconnect BLE GATT first — camera requires this before classic bonding.
    // Start classic discovery only after the BLE disconnect event lands: the
    // camera becomes classic-discoverable once the BLE link is fully down
    // (D5600 takes ~2.7s to release on Android). A 5s fallback covers a
    // missed event.
    this.setState(ConnectionState.Bonding, '正在通过经典蓝牙搜索相机…');
    hilog.info(0x0001, TAG, '[CHECKPOINT] Disconnecting BLE GATT for classic bonding');
    this.pendingBondingDiscovery = true;
    this.bleClient.disconnect();

    setTimeout(() => {
      if (this.pendingBondingDiscovery && this._state === ConnectionState.Bonding) {
        this.pendingBondingDiscovery = false;
        hilog.warn(0x0001, TAG, '[CHECKPOINT] BLE disconnect event missed — starting discovery anyway');
        this.startClassicDiscoveryForBonding();
      }
    }, 5000);
  }

  private startClassicDiscoveryForBonding(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] Starting classic BT discovery for bonding');
    this.bondingDiscoveryActive = true;

    let bondAttempted: boolean = false;

    try {
      connection.startBluetoothDiscovery();
      hilog.info(0x0001, TAG, '[CHECKPOINT] Classic discovery started');
    } catch (err) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] startBluetoothDiscovery FAILED: ${JSON.stringify(err)}`);
      this.finishBonding(false);
      return;
    }

    // Use discoveryResult event (v18 API) which gives deviceId + deviceName + rssi.
    // Unregister any previous listener first (connection.on accumulates).
    if (this.bondDiscoveryCb) connection.off('discoveryResult', this.bondDiscoveryCb);
    this.bondDiscoveryCb = (data: Object) => {
      // Guard: once bonding finished (or was abandoned), ignore late results —
      // a camera that re-broadcasts under a new random address would otherwise
      // trigger a second pairDevice after BONDED.
      if (!this.bondingDiscoveryActive) return;
      const devs: Object[] = Array.isArray(data) ? data as Object[] : [data];
      for (let i = 0; i < devs.length; i++) {
        const d = devs[i] as Record<string, Object>;
        const name = (d['deviceName'] || '') as string;
        const addr = (d['deviceId'] || '') as string;
        if (!name || !addr) continue;

        hilog.info(0x0001, TAG, `[DISCOVERY] found: name='${name}' addr=${addr}`);

        // Match camera by name — classic BT name ≈ BLE name (e.g. Z_6_2_<serial>,
        // D5600_<serial>, ...) or contains the serial or model. Normalize underscores.
        const nameNorm = name.replace(/_/g, '').toLowerCase();
        const bleNorm = (this.cameraName || '').replace(/_/g, '').toLowerCase();
        const serialNorm = this.cameraSerial.replace(/-/g, '').toLowerCase();
        const model = (this.cameraName || '').split('_')[0].toLowerCase();
        // Match the TARGET camera only — other paired cameras (e.g. a Z-series
        // body that is also broadcasting) must NOT match. Any camera-specific
        // rule like name.includes('Z_') would mis-pair when 2 cameras coexist.
        // The model-only fallback is the LAST resort and only when the serial is
        // still unknown: with a known serial, two same-model bodies (e.g. two
        // D5600) must be told apart by serial, never by model alone.
        const matches = (bleNorm.length > 0 && (nameNorm.includes(bleNorm) || bleNorm.includes(nameNorm)))
          || (serialNorm.length > 0 && nameNorm.includes(serialNorm))
          || (model.length >= 3 && nameNorm.includes(model) && serialNorm.length === 0);
        if (!matches) continue;

        hilog.info(0x0001, TAG, `[CHECKPOINT] Matched camera! Trying pairDevice('${addr}')`);
        try { connection.stopBluetoothDiscovery(); } catch (e) {}
        bondAttempted = true;

        try {
          connection.pairDevice(addr);
          this._statusMessage = 'Pairing with camera... accept dialog if shown.';
        } catch (err) {
          hilog.error(0x0001, TAG, `[CHECKPOINT] pairDevice FAILED: ${JSON.stringify(err)}`);
          this.finishBonding(false);
          return;
        }

        // Listen for bond state — filtered to the target device: an unrelated
        // device's bond transition must not abort (or falsely complete) ours.
        if (this.bondStateCb) connection.off('bondStateChange', this.bondStateCb);
        this.bondStateCb = (bondData: connection.BondStateParam) => {
          hilog.info(0x0001, TAG,
            `[CHECKPOINT] bondState: deviceId=${bondData.deviceId} state=${bondData.state}`);
          if (bondData.deviceId !== addr) return; // another device — ignore
          if (!this.bondingDiscoveryActive) return; // stale — already finished
          if (bondData.state === connection.BondState.BOND_STATE_BONDED) {
            hilog.info(0x0001, TAG, '[CHECKPOINT] BONDED!');
            this.bondingDiscoveryActive = false;
            try { connection.stopBluetoothDiscovery(); } catch (e) {}
            this.finishBonding(true);
          } else if (bondData.state !== connection.BondState.BOND_STATE_BONDING) {
            // NONE/INVALID after bonding started = failure — fail fast instead
            // of waiting out the 20s timeout (and no false success dialog).
            hilog.warn(0x0001, TAG, `[CHECKPOINT] Bond failed (state=${bondData.state}) — finishing`);
            this.bondingDiscoveryActive = false;
            try { connection.stopBluetoothDiscovery(); } catch (e) {}
            this.finishBonding(false);
          }
        };
        connection.on('bondStateChange', this.bondStateCb);

        setTimeout(() => {
          if (this._state === ConnectionState.Bonding) {
            hilog.warn(0x0001, TAG, '[CHECKPOINT] Bonding response timeout (20s)');
            this.finishBonding(false);
          }
        }, 20000);
        return;
      }
    };
    connection.on('discoveryResult', this.bondDiscoveryCb);

    // Timeout: 15 seconds
    setTimeout(() => {
      if (!bondAttempted && this._state === ConnectionState.Bonding) {
        hilog.warn(0x0001, TAG, '[CHECKPOINT] Classic discovery timeout — proceeding without bond');
        try { connection.stopBluetoothDiscovery(); } catch (e) {}
        this.finishBonding(false);
      }
    }, 15000);
  }

  private handleLinkLost(): void {
    if (this._state === ConnectionState.Ready) {
      this.stopGpsLoop();
      if (this.savedCamera && this.reconnectEnabled) {
        this.scheduleReconnect();
      } else {
        this.releaseOwnership();
        this.cameraSerial = '';
        this.cameraName = '';
        this.stopBackgroundTask();
        this.setState(ConnectionState.Idle, '相机已断开，请重新连接');
      }
      return;
    }
    if (this._state === ConnectionState.Idle || this._state === ConnectionState.Bonding) {
      return;
    }
    // During reconnect/pairing, BLE drop is transient — graceful reset.
    // Keep-connected means keep trying: no attempt cap (backoff itself caps
    // the rate at 60s). Only the user's disconnect()/toggle-off stops it.
    this.pairingStep = 0;
    this.currentStage1 = null;
    if (this.savedCamera && this.reconnectEnabled) {
      this.scheduleReconnect();
    } else {
      this.releaseOwnership();
      this.cameraSerial = '';
      this.cameraName = '';
      this.stopBackgroundTask();
      this.setState(ConnectionState.Idle, '连接已断开，请重新连接');
    }
  }

  private scheduleReconnect(): void {
    if (!this.savedCamera) return;
    // Dedupe: a later schedule replaces any pending one (BleError can arrive
    // multiple times for the same link loss — timeout + late error callback).
    if (this.reconnectTimerId !== null) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = null;
    }
    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s...
    const delays = [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000, 60000, 60000];
    const delay = delays[Math.min(this.reconnectRetries, delays.length - 1)];
    this.reconnectRetries++;
    hilog.info(0x0001, TAG, `[RECONNECT] attempt ${this.reconnectRetries} in ${delay}ms`);
    this.setState(ConnectionState.Idle, `正在自动重连（第 ${this.reconnectRetries} 次）…`);
    const cam = this.savedCamera;
    this.reconnectTimerId = setTimeout(() => {
      this.reconnectTimerId = null;
      if (this.owner === 'connection' && cam && this.reconnectEnabled) {
        this.startReconnect(cam);
      }
    }, delay);
  }

  private unregisterBondListeners(): void {
    if (this.bondDiscoveryCb) { connection.off('discoveryResult', this.bondDiscoveryCb); this.bondDiscoveryCb = null; }
    if (this.bondStateCb) { connection.off('bondStateChange', this.bondStateCb); this.bondStateCb = null; }
  }

  private finishBonding(bonded: boolean): void {
    this.bondingDiscoveryActive = false;
    this.pendingBondingDiscovery = false;
    this.unregisterBondListeners();
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
    // Only a real BONDED marks pairing complete. On failure keep pairingStep
    // < 6 so PairingPage does not show a false "配对成功" dialog.
    if (bonded) this.pairingStep = 6;
    // Pairing mode: BLE was disconnected for classic bonding. Set Idle — user must
    // reconnect manually from ConnectionPage.
    // Connection mode: BLE remains connected. Ready + GPS loop.
    if (this.owner === 'pairing') {
      this.setState(ConnectionState.Idle, '');
      this.releaseOwnership(); // after setState so listener sees owner='pairing' for dialog
    } else {
      this.setState(ConnectionState.Ready,
        '已连接');
      this.startGpsLoop();
    }
  }

  private onBonded(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onBonded()');
    this.pairingStep = 6;

    // Only save for PAIR mode (new cameras). Reconnects already have saved data.
    if (this.isPairMode && this.currentStage1) {
      const deviceId = this.bleClient.getDeviceId();
      const camera = new PairedCamera(
        this.cameraName || deviceId, deviceId, 1,
        this.currentStage1.device, this.currentStage1.nonce,
        this.controllerName
      );
      this.prefs.saveCameraSync(camera);
      hilog.info(0x0001, TAG,
        `[CHECKPOINT] Paired camera saved: ${camera.name}`);
    }

    // RECONNECT mode: BLE is still connected, go Ready + GPS
    // PAIR mode: handled by checkBondedAndFinish → classic bonding → finishBonding
    if (!this.isPairMode) {
      this.setState(ConnectionState.Ready, '已连接');
      this.startGpsLoop();
    }
  }

  // ==================== Lifecycle (App Background/Foreground) ====================

  /**
   * Called from EntryAbility.onBackground().
   * Switches GPS to slow polling and ensures LOCATION background mode is active.
   */
  onAppBackground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Background');
    this.isForeground = false;
    if (this._state === ConnectionState.Ready) {
      this.stopGpsLoop();
      this.startGpsLoop(5000); // switch to slow background interval
    }
  }

  /**
   * Called from EntryAbility.onForeground().
   * Restores fast GPS polling for foreground.
   */
  onAppForeground(): void {
    hilog.info(0x0001, TAG, '[LIFECYCLE] App → Foreground');
    this.isForeground = true;
    if (this._state === ConnectionState.Ready) {
      this.stopGpsLoop();
      this.startGpsLoop(); // restore default 1500ms interval
    }
  }

  // ==================== Background Task ====================

  /**
   * Apply for a ContinuousTask to keep BLE + GPS alive in background.
   * Uses wantAgent to show a notification that the user can tap to return to the app.
   */
  private async startBackgroundTask(): Promise<void> {
    if (this.backgroundTaskStarted || !this.abilityContext) return;

    const ctx = this.abilityContext;

    // Build WantAgent for notification click → reopen EntryAbility
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

  private stopBackgroundTask(): void {
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

  // ==================== State Management ====================

  private setState(state: ConnectionState, message: string): void {
    this._state = state;
    this._statusMessage = message;
    // Terminal states end the connect watchdog
    if (state === ConnectionState.Ready || state === ConnectionState.Idle
      || state === ConnectionState.Error || state === ConnectionState.Bonding) {
      this.clearConnectTimeout();
    }
    hilog.info(0x0001, TAG, `[CHECKPOINT] STATE: ${state} — ${message}`);
    for (let i = 0; i < this.stateListeners.length; i++) {
      this.stateListeners[i](state, message);
    }
  }

  private advancePairingStep(step: number): void {
    this.pairingStep = step;
    if (this._state === ConnectionState.Pairing) {
      // Handshake progressed inside the Pairing state — re-broadcast so the
      // pairing tab refreshes its (x/4) display immediately.
      hilog.info(0x0001, TAG, `[CHECKPOINT] pairingStep=${step} (re-broadcast)`);
      for (let i = 0; i < this.stateListeners.length; i++) {
        this.stateListeners[i](this._state, this._statusMessage);
      }
    }
  }
}

// Global singleton — shared across all pages
export const cameraService = new CameraService();
