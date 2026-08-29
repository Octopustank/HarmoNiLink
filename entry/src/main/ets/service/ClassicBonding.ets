/**
 * ClassicBonding.ets — classic-Bluetooth bonding coordinator
 *
 * Extracted from CameraSession. During NEW-pairing, Nikon bodies require the
 * BLE GATT to be fully released before they become classic-BT discoverable;
 * this coordinator then runs the classic phase: start discovery, match the
 * TARGET camera among the results (by broadcast name / serial / model — never
 * mis-pairing a sibling body), fire pairDevice, and track the bond state to
 * completion or failure.
 *
 * Lifecycle contract with the owning session (ClassicBondingHost):
 *   markPending()   — session is waiting for the BLE-down event first
 *   takePending()   — BLE went down; consume the wait and let begin() run
 *   begin()         — start discovery + pair + bond tracking
 *   abort()         — cancel everything (disconnect / link lost / cancel)
 *   onBondingFinished(bonded, msg) — fired exactly once per attempt; the
 *                     session settles state, persists the camera, releases
 *                     ownership
 *
 * Scan/discovery discipline (P0-2): this class ONLY stops classic discovery
 * it started itself; the BLE scanner's own classic channel is untouched.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { connection } from '@kit.ConnectivityKit';

const TAG = 'HarmoNiLink-CameraService';

/** The slice of CameraSession the bonding coordinator needs. */
export interface ClassicBondingHost {
  /** BLE broadcast name (e.g. Z_6_2_<serial> / D5600_<serial>). */
  getCameraName(): string;
  /** Serial extracted from stage 4 (may be garbled on D-series → falls back
   * to the broadcast name upstream). */
  getCameraSerial(): string;
  /** True while the session is in its Bonding state — guards the late
   * timeouts against firing after the attempt already settled. */
  isInBondingState(): boolean;
  /** Bond attempt concluded (bonded=true persisted the camera upstream). */
  onBondingFinished(bonded: boolean, failMessage: string): void;
  /** Progress line for the UI (no state re-broadcast). */
  onProgressMessage(message: string): void;
}

export class ClassicBonding {
  private host: ClassicBondingHost;
  // True while classic discovery started by THIS coordinator is running.
  private discoveryActive: boolean = false;
  // True while waiting for the BLE disconnect event before starting classic
  // discovery — older bodies (D5600) only become classic-discoverable once
  // BLE is fully down.
  private pendingDiscovery: boolean = false;
  // Registered classic-discovery/bond listeners — kept by reference so
  // abort() can unregister them (connection.on accumulates otherwise).
  private bondDiscoveryCb: ((data: Object) => void) | null = null;
  private bondStateCb: ((data: connection.BondStateParam) => void) | null = null;

  constructor(host: ClassicBondingHost) {
    this.host = host;
  }

  /** True while this coordinator owns an active classic discovery. */
  isActive(): boolean { return this.discoveryActive; }

  /** Announce intent to bond once the BLE link is fully down. */
  markPending(): void { this.pendingDiscovery = true; }

  /** BLE went down: consume the pending wait. Returns true if a wait was
   * pending (the caller should begin() now). */
  takePending(): boolean {
    if (!this.pendingDiscovery) return false;
    this.pendingDiscovery = false;
    return true;
  }

  /** Cancel everything: clear flags, unregister listeners, stop classic
   * discovery ONLY if this coordinator started it (a sibling session's or
   * the scanner's discovery must survive — P0-2). Idempotent. */
  abort(): void {
    const owned = this.discoveryActive || this.pendingDiscovery;
    this.discoveryActive = false;
    this.pendingDiscovery = false;
    this.unregisterListeners();
    if (owned) {
      try { connection.stopBluetoothDiscovery(); } catch (e) {}
    }
  }

  /** Start classic discovery, match the target camera, pairDevice, and track
   * the bond state. Fires host.onBondingFinished exactly once on conclusion
   * (or never, if abort() wins the race — the session settles instead). */
  begin(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] Starting classic BT discovery for bonding');
    this.discoveryActive = true;

    let bondAttempted: boolean = false;

    try {
      connection.startBluetoothDiscovery();
      hilog.info(0x0001, TAG, '[CHECKPOINT] Classic discovery started');
    } catch (err) {
      hilog.error(0x0001, TAG, `[CHECKPOINT] startBluetoothDiscovery FAILED: ${JSON.stringify(err)}`);
      this.discoveryActive = false;
      this.host.onBondingFinished(false, '经典蓝牙发现启动失败');
      return;
    }

    // Use discoveryResult event (v18 API) which gives deviceId + deviceName + rssi.
    // Unregister any previous listener first (connection.on accumulates).
    if (this.bondDiscoveryCb) { try { connection.off('discoveryResult', this.bondDiscoveryCb); } catch (e) {} }
    this.bondDiscoveryCb = (data: Object) => {
      // Guard: once bonding finished (or was abandoned), ignore late results —
      // a camera that re-broadcasts under a new random address would otherwise
      // trigger a second pairDevice after BONDED.
      if (!this.discoveryActive) return;
      const devs: Object[] = Array.isArray(data) ? data as Object[] : [data];
      for (let i = 0; i < devs.length; i++) {
        const d = devs[i] as Record<string, Object>;
        const name = (d['deviceName'] || '') as string;
        const addr = (d['deviceId'] || '') as string;
        if (!name || !addr) continue;

        hilog.info(0x0001, TAG, `[DISCOVERY] found: name='${name}' addr=${addr}`);

        if (!this.matchesTarget(name)) continue;

        hilog.info(0x0001, TAG, `[CHECKPOINT] Matched camera! Trying pairDevice('${addr}')`);
        try { connection.stopBluetoothDiscovery(); } catch (e) {}
        bondAttempted = true;

        try {
          connection.pairDevice(addr);
          this.host.onProgressMessage('Pairing with camera... accept dialog if shown.');
        } catch (err) {
          hilog.error(0x0001, TAG, `[CHECKPOINT] pairDevice FAILED: ${JSON.stringify(err)}`);
          this.discoveryActive = false;
          this.host.onBondingFinished(false, '配对请求失败');
          return;
        }

        // Listen for bond state — filtered to the target device: an unrelated
        // device's bond transition must not abort (or falsely complete) ours.
        if (this.bondStateCb) connection.off('bondStateChange', this.bondStateCb);
        this.bondStateCb = (bondData: connection.BondStateParam) => {
          hilog.info(0x0001, TAG,
            `[CHECKPOINT] bondState: deviceId=${bondData.deviceId} state=${bondData.state}`);
          if (bondData.deviceId !== addr) return; // another device — ignore
          if (!this.discoveryActive) return; // stale — already finished
          if (bondData.state === connection.BondState.BOND_STATE_BONDED) {
            hilog.info(0x0001, TAG, '[CHECKPOINT] BONDED!');
            this.discoveryActive = false;
            try { connection.stopBluetoothDiscovery(); } catch (e) {}
            this.host.onBondingFinished(true, '');
          } else if (bondData.state !== connection.BondState.BOND_STATE_BONDING) {
            // NONE/INVALID after bonding started = failure — fail fast instead
            // of waiting out the 20s timeout (and no false success dialog).
            hilog.warn(0x0001, TAG, `[CHECKPOINT] Bond failed (state=${bondData.state}) — finishing`);
            this.discoveryActive = false;
            try { connection.stopBluetoothDiscovery(); } catch (e) {}
            this.host.onBondingFinished(false, '配对被拒绝或失败');
          }
        };
        connection.on('bondStateChange', this.bondStateCb);

        setTimeout(() => {
          if (this.host.isInBondingState()) {
            hilog.warn(0x0001, TAG, '[CHECKPOINT] Bonding response timeout (20s)');
            this.host.onBondingFinished(false, '绑定响应超时');
          }
        }, 20000);
        return;
      }
    };
    try { connection.on('discoveryResult', this.bondDiscoveryCb); } catch (e) {}

    // Timeout: 15 seconds
    setTimeout(() => {
      if (!bondAttempted && this.host.isInBondingState()) {
        hilog.warn(0x0001, TAG, '[CHECKPOINT] Classic discovery timeout — proceeding without bond');
        try { connection.stopBluetoothDiscovery(); } catch (e) {}
        this.host.onBondingFinished(false, '未发现相机，配对超时');
      }
    }, 15000);
  }

  /**
   * Match camera by name — classic BT name ≈ BLE name (e.g. Z_6_2_<serial>,
   * D5600_<serial>, ...) or contains the serial or model. Normalize underscores.
   * Match the TARGET camera only — other paired cameras (e.g. a Z-series
   * body that is also broadcasting) must NOT match. Any camera-specific
   * rule like name.includes('Z_') would mis-pair when 2 cameras coexist.
   * The model-only fallback is the LAST resort and only when the serial is
   * still unknown: with a known serial, two same-model bodies (e.g. two
   * D5600) must be told apart by serial, never by model alone.
   */
  private matchesTarget(name: string): boolean {
    const cameraName = this.host.getCameraName();
    const cameraSerial = this.host.getCameraSerial();
    const nameNorm = name.replace(/_/g, '').toLowerCase();
    const bleNorm = (cameraName || '').replace(/_/g, '').toLowerCase();
    const serialNorm = cameraSerial.replace(/-/g, '').toLowerCase();
    const model = (cameraName || '').split('_')[0].toLowerCase();
    return (bleNorm.length > 0 && (nameNorm.includes(bleNorm) || bleNorm.includes(nameNorm)))
      || (serialNorm.length > 0 && nameNorm.includes(serialNorm))
      || (model.length >= 3 && nameNorm.includes(model) && serialNorm.length === 0);
  }

  private unregisterListeners(): void {
    if (this.bondDiscoveryCb) { try { connection.off('discoveryResult', this.bondDiscoveryCb); } catch (e) {} this.bondDiscoveryCb = null; }
    if (this.bondStateCb) { try { connection.off('bondStateChange', this.bondStateCb); } catch (e) {} this.bondStateCb = null; }
  }
}
