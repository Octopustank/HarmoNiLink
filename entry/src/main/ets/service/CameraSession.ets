/**
 * CameraSession.ets — Per-camera connection session
 *
 * Phase 0: extracted from CameraService with ZERO behaviour change. A single
 * camera's state (pairing/connect/reconnect) that was previously scattered
 * across CameraService's singular fields now lives here. The Hub (CameraService)
 * still owns shared resources — scanner, prefs, pairing engine, satellite
 * subscription, background task, GPS ticker, ownership, state broadcast — and
 * exposes them to this session via a hub reference.
 *
 * Deliberately NOT in this session (kept in the Hub, per the multi-camera
 * design): the GPS ticker (one location source fanning out to all Ready
 * sessions), the reconnect-enabled flag (global toggle), and the satellite
 * subscription. A session only owns what is per-connection.
 *
 * Phase 1+ will let the Hub hold multiple sessions. For now the Hub enforces
 * "at most one" so v1.7 behaviour is identical.
 *
 * [CHECKPOINT] log prefix is intentionally identical to the pre-split
 * CameraService so regression log diffs stay clean.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';
import { PairingMessage } from '../ble/protocol/PairingMessage';
import { BleClient } from '../ble/BleClient';
import { DiscoveredCamera } from '../ble/BleScanner';
import {
  BleConnected, BleDisconnected, BleServicesDiscovered, BleMtuChanged,
  BlePairIndication, BleNot1Notification, BleWriteDone, BleError, BleEvent
} from '../ble/BleEvent';
import { CameraService, ConnectionState } from './CameraService';

const TAG = 'HarmoNiLink-CameraService';
const DEFAULT_CONTROLLER_NAME: string = 'HarmoNiLink';

/**
 * A single camera's connection lifecycle.
 *
 * Owns all per-camera state and logic; delegates shared-resource access to the
 * Hub (CameraService) it was created by.
 */
export class CameraSession {
  private hub: CameraService;

  // ==== Per-camera state (moved out of CameraService) ====

  // Each session owns its own GATT client — per-connection isolation (Phase 1
  // multi-camera). The Hub's scanner/prefs/pairing-engine stay shared.
  private bleClient: BleClient = new BleClient();

  // Per-session connection state (Phase 1: the Hub no longer mirrors a single
  // global _state — each session broadcasts its own, keyed by camera name).
  private state: ConnectionState = ConnectionState.Idle;
  private statusMessage: string = '';

  // Pairing state
  private savedCamera: PairedCamera | null = null;
  private controllerName: string = DEFAULT_CONTROLLER_NAME;
  private currentStage1: PairingMessage | null = null;
  private pairingStep: number = 0; // 0=idle, 1=stage1sent, 2=stage3sent, 3=stage4got, 4=idwritten, 5=bonding, 6=ready
  private isPairMode: boolean = true; // true=NEW, false=RECONNECT
  private cameraSerial: string = '';
  private cameraName: string = ''; // real camera name (e.g. Z_6_2_<serial> / D5600_<serial>), set during scan

  // Classic discovery / bonding state
  private bondingDiscoveryActive: boolean = false;
  // True while waiting for the BLE disconnect event to start classic discovery —
  // older bodies (D5600) only become classic-discoverable once BLE is fully down.
  private pendingBondingDiscovery: boolean = false;
  // Registered classic-discovery/bond listeners — kept by reference so
  // finishBonding can unregister them (connection.on accumulates otherwise).
  private bondDiscoveryCb: ((data: Object) => void) | null = null;
  private bondStateCb: ((data: connection.BondStateParam) => void) | null = null;

  // Connect watchdog — aborts stalled pairing against unresponsive devices
  private connectTimeoutId: number | null = null;

  // Pending auto-reconnect timer — dedupes scheduleReconnect() calls
  private reconnectTimerId: number | null = null;
  private reconnectRetries: number = 0; // backoff counter

  // True once a [ROOT] link-death cause (watchdog / write-*) has been logged
  // for the current link. Suppresses the nested "cause=disconnected" marker
  // that the teardown disconnect() emits right after the root cause.
  private linkLostRootMarked: boolean = false;

  // "Camera is waiting for another paired device" hint throttle timestamp.
  private lastPairTargetHintAt: number = 0;

  constructor(hub: CameraService) {
    this.hub = hub;
  }

  // ==== Getters / accessors used by the Hub's public API ====

  getSavedCamera(): PairedCamera | null { return this.savedCamera; }
  getPairingStep(): number { return this.pairingStep; }
  getCameraSerial(): string { return this.cameraSerial; }
  getCameraName(): string { return this.cameraName; }
  getControllerName(): string { return this.controllerName; }
  getState(): ConnectionState { return this.state; }
  getStatusMessage(): string { return this.statusMessage; }

  /** GPS fan-out write outlets — called by the Hub's single GPS ticker. */
  isConnected(): boolean { return this.bleClient.isConnected(); }
  writeTime(payload: Uint8Array): void { this.bleClient.writeTime(payload); }
  writeGeo(payload: Uint8Array): void { this.bleClient.writeGeo(payload); }

  /** Hub cancels a pending reconnect when the global toggle is turned off. */
  cancelReconnectTimer(): void {
    if (this.reconnectTimerId !== null) {
      clearTimeout(this.reconnectTimerId);
      this.reconnectTimerId = null;
    }
  }

  /** Watchdog cleanup — Hub.setState invokes this on terminal states. */
  clearConnectTimeout(): void {
    if (this.connectTimeoutId !== null) {
      clearTimeout(this.connectTimeoutId);
      this.connectTimeoutId = null;
    }
  }

  // ==================== Connect Flow (Connection Page) ====================

  startReconnect(camera: PairedCamera): boolean {
    if (!this.hub.requestOwnership('connection')) return false;
    // Re-entry guard: a double-tap would otherwise open two GATT clients and
    // two scan sessions racing each other.
    if (this.state === ConnectionState.Scanning || this.state === ConnectionState.Connecting
      || this.state === ConnectionState.Discovering || this.state === ConnectionState.Pairing) {
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
    this.hub.scanner.startScan((cameras: DiscoveredCamera[]) => {
      // Reliable reconnect: match the device ID of the camera's CURRENT
      // pairing target (this controller) from manufacturer data (companyID
      // 0x0399). It identifies the pairing relationship, not the camera body
      // (re-pairing changes it; a camera waiting for another controller
      // broadcasts that controller's ID instead). Nikon rotates its BLE
      // address on restart, so the saved address is stale after sleep; the
      // device ID picks the camera's CURRENT address. Name match is only a
      // fallback (e.g. pairing-mode camera that no longer advertises 0x0399).
      //
      // Both sides are normalized to unsigned 32-bit before comparing: the
      // manufacturer parse returns unsigned, but a legacy-persisted
      // camera.device may still be signed-negative for IDs >= 2^31. `>>> 0`
      // reconciles them regardless of how the saved value was stored.
      // Two passes: the stable device-ID match always wins over name. A
      // single-pass `devMatch || nameMatch` find could return an earlier
      // name-matching entry (a different camera sharing the broadcast name,
      // or a name hit listed before the true dev hit) and skip the real
      // device-ID match that came later.
      const devHit = cameras.find((c) =>
        c.manufacturerDevice !== undefined
          && (c.manufacturerDevice >>> 0) === (camera.device >>> 0));
      const found = devHit ?? cameras.find((c) => c.deviceName === camera.name);
      const foundDevMatch = devHit !== undefined;
      if (found) {
        this.hub.scanner.stopScan();
        hilog.info(0x0001, TAG,
          `[CHECKPOINT] reconnect scan found: newAddr=${found.deviceId} savedAddr=${camera.address} devMatch=${foundDevMatch}`);
        // Update address
        const updated = new PairedCamera(
          camera.name, found.deviceId, camera.addressType,
          camera.device, camera.nonce, camera.controllerName
        );
        this.savedCamera = updated;
        this.hub.prefs.saveCameraSync(updated);
        this.connectToDevice(found.deviceId);
      }
    });

    // Timeout: fall back to the saved address after 10 seconds. This is NOT
    // just a last-ditch fallback — connecting to the (possibly stale) address
    // is a deliberate "poke" that wakes a sleeping camera. Once woken, the
    // camera re-advertises a fresh address that the next scan picks up
    // (observed in logs: poke -> disconnect -> fresh scan -> reconnect).
    setTimeout(() => {
      if (this.state === ConnectionState.Scanning && this.hub.getOwner() === 'connection') {
        hilog.info(0x0001, TAG, '[CHECKPOINT] reconnect scan timeout, using saved address');
        this.hub.scanner.stopScan();
        this.connectToDevice(camera.address);
      }
    }, 10000);
    return true;
  }

  // ==================== Pair Flow (Pairing Page) ====================

  selectDiscoveredCamera(camera: DiscoveredCamera): void {
    if (this.hub.getOwner() !== 'pairing') {
      hilog.warn(0x0001, TAG, '[OWNER] selectDiscoveredCamera ignored — not pairing owner');
      return;
    }
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] selectDiscoveredCamera: name='${camera.deviceName}' id=${camera.deviceId}`);

    // Stop BLE scan only (no state change — avoids spurious Idle that resets PairingPage isPairing)
    this.hub.scanner.stopScan();

    // Check if we have saved data for this camera — if so, proceed with pair mode anyway
    // (ownership is pairing; reconnect flow requires connection ownership)
    const saved = this.hub.prefs.loadSavedCamerasSync();
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
    this.controllerName = this.hub.prefs.getOrCreateControllerName();

    hilog.info(0x0001, TAG,
      `[CHECKPOINT] Trying BLE connect to ${camera.deviceId}`);
    this.connectToDevice(camera.deviceId);
  }

  // ==================== Disconnect ====================

  disconnect(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] disconnect() called');
    this.hub.stopGpsLoop();
    this.hub.stopBackgroundTask();
    this.clearConnectTimeout();
    // Release ownership only if THIS session holds it (in-flight connect/pair).
    // A Ready session's owner is already released (or belongs to another tab's
    // pairing) — releasing here would clobber the pairing tab's ownership.
    const st = this.state;
    if (st === ConnectionState.Scanning || st === ConnectionState.Connecting
      || st === ConnectionState.Discovering || st === ConnectionState.Pairing
      || st === ConnectionState.Bonding) {
      this.hub.releaseOwnership();
    }
    // Cancel any bonding in flight — otherwise a late BONDED event (or the user
    // confirming a pending system dialog) could finish a pairing that was
    // cancelled, producing a ghost "已连接" with no connection.
    this.bondingDiscoveryActive = false;
    this.pendingBondingDiscovery = false;
    this.unregisterBondListeners();
    this.pairingStep = 0;
    this.currentStage1 = null;
    this.cameraSerial = '';
    this.cameraName = '';
    // Idle BEFORE teardown so the synchronous BleDisconnected hits the stale guard.
    this.setState(ConnectionState.Idle, '已断开');
    this.bleClient.disconnect();
    this.hub.scanner.stopScan();
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
  }

  /**
   * User-initiated cancel during pairing (connecting/discovering/pairing/bonding).
   * Fully resets BLE + classic discovery + ownership so the UI returns to idle.
   */
  cancelPairing(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] cancelPairing() called');
    this.hub.scanner.stopScan();
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
    this.disconnect();
  }

  // ==================== Private — connection / handshake ====================

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
      const st = this.state;
      if (st === ConnectionState.Ready || st === ConnectionState.Idle
        || st === ConnectionState.Error || st === ConnectionState.Bonding) {
        return; // already settled — nothing to abort
      }
      hilog.warn(0x0001, TAG, '[CHECKPOINT] Connect watchdog fired (60s) — aborting stalled pairing');
      this.linkLostRootMarked = true;
      hilog.warn(0x0001, TAG, '[CHECKPOINT] LINK LOST [ROOT] cause=watchdog');
      this.bleClient.disconnect();
      this.hub.scanner.stopScan();
      try { connection.stopBluetoothDiscovery(); } catch (e) {}
      // Route through the unified recovery path instead of dying on Error —
      // auto-reconnect keeps trying while the camera is unavailable.
      this.handleLinkLost();
    }, 60000);

    this.bleClient.connect(deviceId, (event: BleEvent) => {
      this.handleBleEvent(event);
    });
  }

  private handleBleEvent(event: BleEvent): void {
    // === Stale event guard ===
    // Ignore events when this session has no connection in flight or up —
    // stale callbacks from a disconnected gattClient (e.g. after disconnect()).
    // Per-session, NOT ownership-based: a Ready session keeps receiving GPS
    // write confirmations while another tab owns the resource.
    const st = this.state;
    const active = st === ConnectionState.Scanning || st === ConnectionState.Connecting
      || st === ConnectionState.Discovering || st === ConnectionState.Pairing
      || st === ConnectionState.Bonding || st === ConnectionState.Ready;
    if (!active) {
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
      if (this.state === ConnectionState.Bonding && this.pendingBondingDiscovery) {
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
      if (this.state === ConnectionState.Pairing && event.message.startsWith('Write')) {
        this.maybeShowPairTargetHint();
      }
      // Link-loss signal, not a terminal state: tear down and let
      // handleLinkLost decide between auto-reconnect and settling.
      this.bleClient.disconnect();
      this.hub.scanner.stopScan();
      try { connection.stopBluetoothDiscovery(); } catch (e) {}
      this.handleLinkLost();
    }
  }

  /**
   * "Camera is waiting for another paired device" hint. Shown at most once
   * per 60s — the reconnect loop fails every ~10s, so without throttling the
   * dialog would spam.
   */
  private maybeShowPairTargetHint(): void {
    if (Date.now() - this.lastPairTargetHintAt < 60000) return;
    this.lastPairTargetHintAt = Date.now();
    hilog.warn(0x0001, TAG, '[CHECKPOINT] Camera may be waiting for another device — showing hint');
    const ctx = this.hub.getAbilityContext();
    if (!ctx) return;
    window.getLastWindow(ctx).then((win) => {
      win.getUIContext().getPromptAction().showDialog({
        title: '连接提示',
        message: `相机端可能未选择本设备。请在相机【已配对设备】里，将当前设备切换为「${this.controllerName || 'HarmoNiLink'}」后重试。`,
        buttons: [{ text: '知道了', color: '#0A59F7' }]
      }).catch((e: BusinessError) => {
        hilog.warn(0x0001, TAG, `[CHECKPOINT] Hint dialog failed: ${e.message}`);
      });
    }).catch((e: BusinessError) => {
      hilog.warn(0x0001, TAG, `[CHECKPOINT] getLastWindow failed: ${e.message}`);
    });
  }

  // ==================== Handshake Logic ====================

  private beginHandshake(): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] beginHandshake: mode=${this.isPairMode ? 'PAIR' : 'RECONNECT'}`);

    this.currentStage1 = this.hub.pairingEngine.createStage1(
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

      const stage3 = this.hub.pairingEngine.verifyStage2AndBuildStage3(stage1, msg);
      if (!stage3) {
        hilog.error(0x0001, TAG, '[CHECKPOINT] Salt verification FAILED — handshake aborted');
        // Release ownership + drop BLE before showing Error, otherwise the
        // pairing tab stays stuck owning a live link with no recovery path.
        this.hub.releaseOwnership();
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
      const serial = this.hub.pairingEngine.extractSerial(msg);
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
      this.hub.prefs.saveCameraSync(camera);
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
      if (this.pendingBondingDiscovery && this.state === ConnectionState.Bonding) {
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
    if (this.bondDiscoveryCb) { try { connection.off('discoveryResult', this.bondDiscoveryCb); } catch (e) {} }
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
          this.statusMessage = 'Pairing with camera... accept dialog if shown.';
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
          if (this.state === ConnectionState.Bonding) {
            hilog.warn(0x0001, TAG, '[CHECKPOINT] Bonding response timeout (20s)');
            this.finishBonding(false);
          }
        }, 20000);
        return;
      }
    };
    try { connection.on('discoveryResult', this.bondDiscoveryCb); } catch (e) {}

    // Timeout: 15 seconds
    setTimeout(() => {
      if (!bondAttempted && this.state === ConnectionState.Bonding) {
        hilog.warn(0x0001, TAG, '[CHECKPOINT] Classic discovery timeout — proceeding without bond');
        try { connection.stopBluetoothDiscovery(); } catch (e) {}
        this.finishBonding(false);
      }
    }, 15000);
  }

  private handleLinkLost(): void {
    if (this.state === ConnectionState.Ready) {
      this.hub.stopGpsLoop();
      if (this.savedCamera && this.hub.isReconnectEnabled()) {
        this.scheduleReconnect();
      } else {
        // Owner was already released on Ready — do NOT release here (would
        // clobber a concurrent pairing tab's ownership).
        this.cameraSerial = '';
        this.cameraName = '';
        this.hub.stopBackgroundTask();
        this.setState(ConnectionState.Idle, '相机已断开，请重新连接');
      }
      return;
    }
    if (this.state === ConnectionState.Idle || this.state === ConnectionState.Bonding) {
      return;
    }
    // During reconnect/pairing, BLE drop is transient — graceful reset.
    // Keep-connected means keep trying: no attempt cap (backoff itself caps
    // the rate at 60s). Only the user's disconnect()/toggle-off stops it.
    this.pairingStep = 0;
    this.currentStage1 = null;
    if (this.savedCamera && this.hub.isReconnectEnabled()) {
      this.scheduleReconnect();
    } else {
      this.hub.releaseOwnership();
      this.cameraSerial = '';
      this.cameraName = '';
      this.hub.stopBackgroundTask();
      this.setState(ConnectionState.Idle, '连接已断开，请重新连接');
    }
  }

  private scheduleReconnect(): void {
    if (!this.savedCamera) return;
    // Dedupe: a later schedule replaces any pending one (BleError can arrive
    // multiple times for the same link loss — timeout + late error callback).
    this.cancelReconnectTimer();
    // Exponential backoff: 1s, 2s, 4s, 8s, 16s, 30s...
    const delays = [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000, 60000, 60000];
    const delay = delays[Math.min(this.reconnectRetries, delays.length - 1)];
    this.reconnectRetries++;
    hilog.info(0x0001, TAG, `[RECONNECT] attempt ${this.reconnectRetries} in ${delay}ms`);
    this.setState(ConnectionState.Idle, `正在自动重连（第 ${this.reconnectRetries} 次）…`);
    const cam = this.savedCamera;
    this.reconnectTimerId = setTimeout(() => {
      this.reconnectTimerId = null;
      // Reconnect unless the pairing tab owns the resource (pairing is serial;
      // a Ready session's owner is already released so 'none' still reconnects).
      if (cam && this.hub.isReconnectEnabled() && this.hub.getOwner() !== 'pairing') {
        this.startReconnect(cam);
      }
    }, delay);
  }

  private unregisterBondListeners(): void {
    if (this.bondDiscoveryCb) { try { connection.off('discoveryResult', this.bondDiscoveryCb); } catch (e) {} this.bondDiscoveryCb = null; }
    if (this.bondStateCb) { try { connection.off('bondStateChange', this.bondStateCb); } catch (e) {} this.bondStateCb = null; }
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
    if (this.hub.getOwner() === 'pairing') {
      this.setState(ConnectionState.Idle, '');
      this.hub.releaseOwnership(); // after setState so listener sees owner='pairing' for dialog
    } else {
      this.setState(ConnectionState.Ready,
        '已连接');
      this.hub.startGpsLoop();
      // Release connection ownership once Ready (see onBonded).
      if (this.hub.getOwner() === 'connection') this.hub.releaseOwnership();
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
      this.hub.prefs.saveCameraSync(camera);
      hilog.info(0x0001, TAG,
        `[CHECKPOINT] Paired camera saved: ${camera.name}`);
    }

    // RECONNECT mode: BLE is still connected, go Ready + GPS
    // PAIR mode: handled by checkBondedAndFinish → classic bonding → finishBonding
    if (!this.isPairMode) {
      this.setState(ConnectionState.Ready, '已连接');
      this.hub.startGpsLoop();
      // Release connection ownership once Ready — the link is established, and
      // the pairing tab must stay free to pair another camera concurrently.
      if (this.hub.getOwner() === 'connection') this.hub.releaseOwnership();
    }
  }

  // ==================== State / pairing step ====================

  private setState(state: ConnectionState, message: string): void {
    this.state = state;
    this.statusMessage = message;
    // Terminal states end the connect watchdog (owned by this session)
    if (state === ConnectionState.Ready || state === ConnectionState.Idle
      || state === ConnectionState.Error || state === ConnectionState.Bonding) {
      this.clearConnectTimeout();
    }
    hilog.info(0x0001, TAG, `[CHECKPOINT] STATE: ${state} — ${message}`);
    this.hub.broadcastSessionState(this.cameraName, state, message);
  }

  private advancePairingStep(step: number): void {
    this.pairingStep = step;
    if (this.state === ConnectionState.Pairing) {
      // Handshake progressed inside the Pairing state — re-broadcast so the
      // pairing tab refreshes its (x/4) display immediately.
      hilog.info(0x0001, TAG, `[CHECKPOINT] pairingStep=${step} (re-broadcast)`);
      this.hub.broadcastSessionState(this.cameraName, this.state, this.statusMessage);
    }
  }
}
