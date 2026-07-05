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
 * For debugging, use: hdc shell hilog -T HarmoNikon
 *
 * Based on nsg/android/.../CameraConnectionService.kt
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ble, connection } from '@kit.ConnectivityKit';
import { geoLocationManager } from '@kit.LocationKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common } from '@kit.AbilityKit';
import { PairedCamera, NikonPairingEngine } from '../ble/protocol/NikonPairingEngine';
import { PairingMessage } from '../ble/protocol/PairingMessage';
import { GeoPayloadGenerator, GpsPosition } from '../ble/protocol/GeoPayloadGenerator';
import { TimePayloadGenerator } from '../ble/protocol/TimePayloadGenerator';
import { BleScanner, DiscoveredCamera } from '../ble/BleScanner';
import { BleClient } from '../ble/BleClient';
import {
  BleConnected, BleDisconnected, BleServicesDiscovered, BleMtuChanged,
  BlePairIndication, BleNot1Notification, BleWriteDone, BleError, BleEvent
} from '../ble/BleEvent';
import { PreferencesRepository } from '../data/PreferencesRepository';

const TAG = 'HarmoNikon-CameraService';
const DEFAULT_CONTROLLER_NAME: string = 'HarmoNikon';

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

export class CameraService {
  // Public state
  private stateListener: StateListener | null = null;
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
  private cameraName: string = ''; // real camera name (Z_6_2_8083511), set during scan

  // GPS loop
  private gpsTimer: number | null = null;
  private backgroundTaskStarted: boolean = false;

  // Context (set from EntryAbility)
  private abilityContext: common.UIAbilityContext | null = null;

  // ==================== Public API ====================

  setStateListener(listener: StateListener): void {
    this.stateListener = listener;
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

  getPairingStep(): number {
    return this.pairingStep;
  }

  setContext(ctx: common.UIAbilityContext): void {
    this.abilityContext = ctx;
    this.prefs.init(ctx); // start async init — loadSavedCamerasSync will return cache once ready
  }

  // ==================== Scan ====================

  // Discovered cameras (populated by scanner callback)
  private discoveredList: DiscoveredCamera[] = [];

  startScan(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] startScan() called');
    this.discoveredList = [];
    this.setState(ConnectionState.Scanning, 'Scanning for cameras...');
    this.scanner.startScan((cameras: DiscoveredCamera[]) => {
      this.discoveredList = cameras;
    });
  }

  getDiscoveredCameras(): DiscoveredCamera[] {
    return this.discoveredList;
  }

  stopScan(): void {
    this.scanner.stopScan();
    if (this._state === ConnectionState.Scanning) {
      this.setState(ConnectionState.Idle, 'Scan stopped.');
    }
  }

  // ==================== Pair Flow ====================

  selectDiscoveredCamera(camera: DiscoveredCamera): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] selectDiscoveredCamera: name='${camera.deviceName}' id=${camera.deviceId}`);

    this.stopScan();

    // Check if we have saved data for this camera — if so, use reconnect mode
    const saved = this.prefs.loadSavedCamerasSync();
    const matched = saved.find((c: PairedCamera) => c.name === camera.deviceName);
    if (matched) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] Camera already paired — using RECONNECT mode');
      this.connectToSavedCamera(matched);
      return;
    }

    // New camera — pair mode
    this.cameraName = camera.deviceName;
    this.isPairMode = true;
    this.savedCamera = null;
    this.controllerName = DEFAULT_CONTROLLER_NAME;

    hilog.info(0x0001, TAG,
      `[CHECKPOINT] Trying BLE connect to ${camera.deviceId}`);
    this.connectToDevice(camera.deviceId);
  }

  // ==================== Connect Flow (Reconnect to saved camera) ====================

  connectToSavedCamera(camera: PairedCamera): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] connectToSavedCamera: name='${camera.name}' addr=${camera.address}`);

    this.isPairMode = false;
    this.savedCamera = camera;
    this.controllerName = camera.controllerName;

    // For reconnect, the camera's BLE address may have changed.
    // Scan for current advertisement by name, fall back to saved address.
    this.setState(ConnectionState.Scanning, `Searching for ${camera.name}...`);
    this.scanner.startScan((cameras: DiscoveredCamera[]) => {
      const found = cameras.find((c) => c.deviceName === camera.name);
      if (found) {
        this.scanner.stopScan();
        hilog.info(0x0001, TAG,
          `[CHECKPOINT] reconnect scan found: newAddr=${found.deviceId} savedAddr=${camera.address}`);
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

    // Timeout: fall back to saved address after 10 seconds
    setTimeout(() => {
      if (this._state === ConnectionState.Scanning) {
        hilog.info(0x0001, TAG, '[CHECKPOINT] reconnect scan timeout, using saved address');
        this.scanner.stopScan();
        this.connectToDevice(camera.address);
      }
    }, 10000);
  }

  // ==================== Disconnect ====================

  disconnect(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] disconnect() called');
    this.stopGpsLoop();
    this.stopBackgroundTask();
    this.bleClient.disconnect();
    this.pairingStep = 0;
    this.currentStage1 = null;
    this.setState(ConnectionState.Idle, 'Disconnected.');
  }

  // ==================== GPS ====================

  private gpsStep: number = 0; // 0=TIME, 1=GEO — alternating

  sendFakeGeo(): void {
    if (!this.bleClient.isConnected()) {
      this._statusMessage = 'BLE not connected — reconnect or scan first';
      hilog.warn(0x0001, TAG, `[CHECKPOINT] sendFakeGeo: BLE not connected`);
      return;
    }
    const geoPayload = GeoPayloadGenerator.buildFake();
    hilog.info(0x0001, TAG, `[GPS] sendFakeGeo: ${geoPayload.length}B`);
    this.bleClient.writeGeo(geoPayload);
  }

  startGpsLoop(intervalMs: number = 1500): void {
    hilog.info(0x0001, TAG, `[GPS] startGpsLoop: interval=${intervalMs}ms`);
    this.stopGpsLoop();
    this.gpsStep = 0;
    // Send TIME immediately, then alternate TIME/GEO
    this.sendGpsTick();
    this.gpsTimer = setInterval(() => { this.sendGpsTick(); }, intervalMs);
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
      const geoPayload = GeoPayloadGenerator.buildFake();
      hilog.info(0x0001, TAG, `[GPS] GEO ${geoPayload.length}B`);
      this.bleClient.writeGeo(geoPayload);
      this.gpsStep = 0;
    }
  }

  stopGpsLoop(): void {
    if (this.gpsTimer !== null) {
      clearInterval(this.gpsTimer);
      this.gpsTimer = null;
      hilog.info(0x0001, TAG, '[CHECKPOINT] GPS loop stopped');
    }
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
    this.setState(ConnectionState.Connecting, `Connecting to ${deviceId}...`);
    this.pairingStep = 0;
    this.currentStage1 = null;

    this.bleClient.connect(deviceId, (event: BleEvent) => {
      this.handleBleEvent(event);
    });
  }

  private handleBleEvent(event: BleEvent): void {
    if (event instanceof BleConnected) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] BLE Connected');
      this.setState(ConnectionState.Discovering, 'Discovering services...');
    } else if (event instanceof BleServicesDiscovered) {
      hilog.info(0x0001, TAG, '[CHECKPOINT] Services Discovered');
      if (this.pairingStep === 0) {
        this.pairingStep = 1;
        this.bleClient.prepare(() => {
          hilog.info(0x0001, TAG, '[CHECKPOINT] prepare done, beginning handshake');
          this.setState(ConnectionState.Pairing, 'Handshaking...');
          this.beginHandshake();
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
      if (this._state === ConnectionState.Ready) {
        // Bonding completed, BLE drop is expected — stop GPS, stay in Ready
        this.stopGpsLoop();
        return;
      }
      if (this._state === ConnectionState.Idle) {
        return;
      }
      if (this._state !== ConnectionState.Bonding) {
        this.setState(ConnectionState.Error, 'Camera disconnected unexpectedly.');
      }
    } else if (event instanceof BleError) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] BLE Error: ${event.message}`);
      if (this._state !== ConnectionState.Ready && this._state !== ConnectionState.Idle) {
        this.setState(ConnectionState.Error, event.message);
      }
    }
  }

  // ==================== Handshake Logic ====================

  private beginHandshake(): void {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] beginHandshake: mode=${this.isPairMode ? 'PAIR' : 'RECONNECT'}`);

    this.currentStage1 = this.pairingEngine.createStage1(
      this.isPairMode ? null : this.savedCamera
    );
    this.pairingStep = 1;

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
        this.setState(ConnectionState.Error, 'Blowfish salt mismatch. Handshake failed.');
        return;
      }

      hilog.info(0x0001, TAG, `[CHECKPOINT] Sending stage 3: ${stage3.toString()}`);
      this.bleClient.writePairMessage(stage3.encode());
      this.pairingStep = 2;
    } else if (this.pairingStep === 2 && msg.stage === 0x04) {
      // Received stage 4 — extract serial
      const serial = this.pairingEngine.extractSerial(msg);
      this.cameraSerial = serial;
      this.pairingStep = 3;

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
    this.pairingStep = 4;

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
        this.pairingStep = 5;
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
      this.pairingStep = 5;
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

    // Disconnect BLE GATT first — camera requires this before classic bonding
    this.setState(ConnectionState.Bonding, 'Searching for camera via classic Bluetooth...');
    hilog.info(0x0001, TAG, '[CHECKPOINT] Disconnecting BLE GATT for classic bonding');
    this.bleClient.disconnect();

    // Start classic Bluetooth discovery to find camera's classic BT address
    // (different from BLE address)
    setTimeout(() => {
      this.startClassicDiscoveryForBonding();
    }, 1000);
  }

  private startClassicDiscoveryForBonding(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] Starting classic BT discovery for bonding');

    // Store the camera name for matching (Z_6_2_8083511)
    const targetName: string = this.cameraSerial || '';
    let bondAttempted: boolean = false;

    try {
      connection.startBluetoothDiscovery();
      hilog.info(0x0001, TAG, '[CHECKPOINT] Classic discovery started');
    } catch (err) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] startBluetoothDiscovery FAILED: ${JSON.stringify(err)}`);
      this.finishBonding();
      return;
    }

    // Use discoveryResult event (v18 API) which gives deviceId + deviceName + rssi
    connection.on('discoveryResult', (data: Object) => {
      const devs: Object[] = Array.isArray(data) ? data as Object[] : [data];
      for (let i = 0; i < devs.length; i++) {
        const d = devs[i] as Record<string, Object>;
        const name = (d['deviceName'] || '') as string;
        const addr = (d['deviceId'] || '') as string;
        if (!name || !addr) continue;

        hilog.info(0x0001, TAG, `[DISCOVERY] found: name='${name}' addr=${addr}`);

        // Match camera by name pattern (e.g., Z_6_2_8083511)
        if (!name.includes('Z_') && !name.includes('8083511')) continue;

        hilog.info(0x0001, TAG, `[CHECKPOINT] Matched camera! Trying pairDevice('${addr}')`);
        try { connection.stopBluetoothDiscovery(); } catch (e) {}
        bondAttempted = true;

        try {
          connection.pairDevice(addr);
          this._statusMessage = 'Pairing with camera... accept dialog if shown.';
        } catch (err) {
          hilog.error(0x0001, TAG, `[CHECKPOINT] pairDevice FAILED: ${JSON.stringify(err)}`);
          this.finishBonding();
          return;
        }

        // Listen for bond state
        connection.on('bondStateChange', (bondData: connection.BondStateParam) => {
          hilog.info(0x0001, TAG,
            `[CHECKPOINT] bondState: deviceId=${bondData.deviceId} state=${bondData.state}`);

          if (bondData.state === connection.BondState.BOND_STATE_BONDED) {
            hilog.info(0x0001, TAG, '[CHECKPOINT] BONDED!');
            this.bondingDiscoveryActive = false;
            try { connection.stopBluetoothDiscovery(); } catch (e) {}
            this.finishBonding();
          } else if (bondData.state === connection.BondState.BOND_STATE_INVALID) {
            hilog.warn(0x0001, TAG, '[CHECKPOINT] Bond INVALID');
          }
        });

        setTimeout(() => {
          if (this._state === ConnectionState.Bonding) {
            hilog.warn(0x0001, TAG, '[CHECKPOINT] Bonding response timeout (20s)');
            this.finishBonding();
          }
        }, 20000);
        return;
      }
    });

    // Timeout: 15 seconds
    setTimeout(() => {
      if (!bondAttempted && this._state === ConnectionState.Bonding) {
        hilog.warn(0x0001, TAG, '[CHECKPOINT] Classic discovery timeout — proceeding without bond');
        try { connection.stopBluetoothDiscovery(); } catch (e) {}
        this.finishBonding();
      }
    }, 15000);
  }

  private tryBondClassicDevice(device: Record<string, Object>, targetName: string, bondAttempted: boolean): void {
    if (bondAttempted) return;
    const name = (device['deviceName'] || device['name']) as string;
    const addr = (device['deviceId'] || device['address'] || device['deviceAddr']) as string;
    if (!name || !addr) return;

    hilog.info(0x0001, TAG, `[DISCOVERY] found: name='${name}' addr=${addr}`);

    // Match by camera name (e.g., Z_6_2_8083511)
    // Also try matching by the serial extracted from stage 4
    const matches = name.includes('Z_') || (name.includes('8083511')) ||
      (targetName && name.includes(targetName.replace('-', '')));

    if (!matches) return;

    hilog.info(0x0001, TAG, `[CHECKPOINT] Matched camera via classic! Trying pairDevice('${addr}')`);
    // Found the classic device — try to bond
    try {
      connection.pairDevice(addr);
      bondAttempted = true;
      this._statusMessage = 'Pairing with camera... accept dialog if shown.';
    } catch (err) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] pairDevice classic FAILED: ${JSON.stringify(err)}`);
      this.finishBonding();
      return;
    }

    // Listen for bond state
    connection.on('bondStateChange', (data: connection.BondStateParam) => {
      hilog.info(0x0001, TAG,
        `[CHECKPOINT] bondState: deviceId=${data.deviceId} addr=${addr} state=${data.state}`);

      if (data.state === connection.BondState.BOND_STATE_BONDED) {
        hilog.info(0x0001, TAG, '[CHECKPOINT] BONDED via classic!');
        this.finishBonding();
      } else if (data.state === connection.BondState.BOND_STATE_INVALID) {
        hilog.warn(0x0001, TAG, '[CHECKPOINT] Bond INVALID');
        // Don't finish here — wait for timeout or retry
      }
    });

    // Timeout for bonding
    setTimeout(() => {
      if (this._state === ConnectionState.Bonding) {
        hilog.warn(0x0001, TAG, '[CHECKPOINT] Bonding response timeout');
        this.finishBonding();
      }
    }, 20000);
  }

  private finishBonding(): void {
    this.bondingDiscoveryActive = false;
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
    this.pairingStep = 6;
    this.setState(ConnectionState.Ready,
      `Paired! Serial: ${this.cameraSerial || 'unknown'}. Tap Reconnect to use.`);
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

    this.setState(ConnectionState.Ready, `Ready. Serial: ${this.cameraSerial || 'unknown'}`);

    // Start GPS loop automatically
    this.startGpsLoop();
  }

  // ==================== Background Task ====================

  private startBackgroundTask(): void {
    if (this.backgroundTaskStarted || !this.abilityContext) return;

    try {
      const ctx = this.abilityContext;
      const bgBT = backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION;
      const bgLoc = backgroundTaskManager.BackgroundMode.LOCATION;

      const start = backgroundTaskManager.startBackgroundRunning as Function;
      start(ctx, bgBT).then(() => {
        hilog.info(0x0001, TAG, '[CHECKPOINT] Background task (BLUETOOTH_INTERACTION) started');
        this.backgroundTaskStarted = true;
      }).catch((err: Error) => {
        hilog.warn(0x0001, TAG,
          `[CHECKPOINT] Background task start failed: ${err.message}`);
      });

      start(ctx, bgLoc).catch((err: Error) => {
        hilog.warn(0x0001, TAG,
          `[CHECKPOINT] Location background task start failed: ${err.message}`);
      });
    } catch (err) {
      hilog.warn(0x0001, TAG, `[CHECKPOINT] startBackgroundTask error: ${JSON.stringify(err)}`);
    }
  }

  private stopBackgroundTask(): void {
    if (!this.backgroundTaskStarted || !this.abilityContext) return;

    try {
      backgroundTaskManager.stopBackgroundRunning(this.abilityContext);
      this.backgroundTaskStarted = false;
      hilog.info(0x0001, TAG, '[CHECKPOINT] Background tasks stopped');
    } catch (err) {
      hilog.warn(0x0001, TAG, `[CHECKPOINT] stopBackgroundTask error: ${JSON.stringify(err)}`);
    }
  }

  // ==================== State Management ====================

  private setState(state: ConnectionState, message: string): void {
    this._state = state;
    this._statusMessage = message;
    hilog.info(0x0001, TAG, `[CHECKPOINT] STATE: ${state} — ${message}`);
    if (this.stateListener) {
      this.stateListener(state, message);
    }
  }
}
