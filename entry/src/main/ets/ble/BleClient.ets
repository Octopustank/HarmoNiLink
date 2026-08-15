import { ble } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BleConnected, BleDisconnected, BleServicesDiscovered,
  BleMtuChanged, BlePairIndication, BleNot1Notification,
  BleWriteDone, BleError, BleEvent
} from './BleEvent';

// One-slot write buffer (newest-wins): when a write arrives while another is
// in flight, it replaces any earlier pending one. A stale TIME payload is
// worthless, a fresh GEO is more valuable — overwrite, never queue more.
class PendingWrite {
  uuid: string = '';
  data: Uint8Array = new Uint8Array(0);
}

const TAG = 'HarmoNiLink-BleClient';

const SVC = '0000DE00-3DD4-4255-8D62-6DC7B9BD5561';
const PAIR = '00002000-3DD4-4255-8D62-6DC7B9BD5561';
const NOT1 = '00002008-3DD4-4255-8D62-6DC7B9BD5561';
const NOT2 = '0000200A-3DD4-4255-8D62-6DC7B9BD5561';
const ID = '00002002-3DD4-4255-8D62-6DC7B9BD5561';
const TIME = '00002006-3DD4-4255-8D62-6DC7B9BD5561';
const GEO = '00002007-3DD4-4255-8D62-6DC7B9BD5561';

export type BleListener = (event: BleEvent) => void;

export class BleClient {
  private listener: BleListener | null = null;
  private gattClient: ble.GattClientDevice | null = null;
  private deviceId: string = '';
  private pairChar: Object | null = null;
  private not1Char: Object | null = null;
  private writeBusy: boolean = false; // prevent concurrent writes
  private pendingWrite: PendingWrite | null = null; // newest-wins buffered write
  private writeTimeoutStreak: number = 0; // consecutive write timeouts before BleError
  private writeSeq: number = 0; // monotonic token — a stale callback must not touch a newer write's timer/busy
  private writeTimeoutId: number | null = null; // safety reset for stalled callbacks
  private servicesDiscovered: boolean = false; // prevent duplicate discovery
  private mtuTimeoutId: number = -1; // cancel MTU timeout when response arrives
  private discoveryRetries: number = 0; // D-series slow service-discovery retries
  private discoveryInFlight: boolean = false; // only one getServices at a time
  private connParamFailed: boolean = false; // LOW_POWER update failed — camera-busy signal

  isConnParamFailed(): boolean { return this.connParamFailed; }

  connect(deviceId: string, listener: BleListener): void {
    hilog.info(0x0001, TAG, `[C] ${deviceId}`);
    this.deviceId = deviceId;
    this.listener = listener;
    this.pairChar = this.not1Char = null;
    this.servicesDiscovered = false;
    this.discoveryRetries = 0;
    this.discoveryInFlight = false;
    this.connParamFailed = false;
    clearTimeout(this.mtuTimeoutId);
    try {
      this.gattClient = ble.createGattClientDevice(deviceId);
      this.gattClient.on('BLEConnectionStateChange', (d: ble.BLEConnectionChangeState) => {
        hilog.info(0x0001, TAG, `[S] ${d.state}`);
        if (d.state === 2) {
          if (this.servicesDiscovered) return; // already set up
          this.emit(new BleConnected());
          // Set low-power connection mode (camera can sleep without dropping BLE)
          try {
            const gatt = this.gattClient as Object as Record<string, Function>;
            if (gatt['updateConnectionParam']) {
              gatt['updateConnectionParam'](ble.ConnectionParam.LOW_POWER).catch((e: Error) => {
                // Failure is a camera-busy signal: on a healthy link this
                // succeeds; when the camera is waiting for another paired
                // device it fails consistently.
                this.connParamFailed = true;
                hilog.warn(0x0001, TAG, `[M] updateConnectionParam fail: ${e.message}`);
              });
            }
          } catch (e) { this.connParamFailed = true; }
          try { this.gattClient?.setBLEMtuSize(517); hilog.info(0x0001, TAG, `[M] setMTU`); } catch (e) {}
          // MTU timeout: if no response in 5s, proceed anyway. 3s was too
          // tight — D5600 on some stacks takes ~4.5s to negotiate MTU, and
          // querying services before the link settles returns an empty list.
          clearTimeout(this.mtuTimeoutId);
          this.mtuTimeoutId = setTimeout(() => {
            hilog.warn(0x0001, TAG, `[M] MTU timeout — discovering anyway`);
            this.discoverServices();
          }, 5000);
        } else if (d.state === 0) this.emit(new BleDisconnected());
      });
      this.gattClient.on('BLEMtuChange', (mtu: number) => {
        hilog.info(0x0001, TAG, `[M] ${mtu}`);
        clearTimeout(this.mtuTimeoutId);
        this.emit(new BleMtuChanged(mtu));
        this.discoverServices();
      });
      this.gattClient.on('BLECharacteristicChange', (d: ble.BLECharacteristic) => {
        const val = toUint8Array(d.characteristicValue);
        const u = (d.characteristicUuid as string ?? '').toLowerCase();
        if (u === PAIR.toLowerCase()) this.emit(new BlePairIndication(val));
        else if (u === NOT1.toLowerCase()) this.emit(new BleNot1Notification(val));
        else if (u === NOT2.toLowerCase()) this.emit(new BleNot1Notification(val)); // treat NOT2 same as NOT1
      });
      this.gattClient.connect();
      hilog.info(0x0001, TAG, `[C] ok`);
    } catch (err) { hilog.error(0x0001, TAG, `[C] ERR ${(err as BusinessError).message}`); }
  }

  disconnect(): void {
    try {
      if (this.gattClient) {
        // NOTE: listeners are intentionally NOT unregistered here. The service
        // needs the BleDisconnected event to act immediately (e.g. start
        // classic discovery once the BLE link is down). close() stops further
        // system callbacks, and CameraService's stale guard ignores events
        // after ownership is released.
        this.gattClient.disconnect();
        this.gattClient.close();
      }
    } catch (e) { hilog.debug(0x0001, TAG, `[C] cleanup: ${JSON.stringify(e)}`); }
    // Synchronous notification — don't rely on async system callbacks that may
    // be swallowed by close().
    this.emit(new BleDisconnected());
    this.gattClient = null;
    this.writeBusy = false;
    this.writeTimeoutStreak = 0; // stale streak must not leak into the next connection
    this.pendingWrite = null; // stale buffered data must not leak into the next connection
    if (this.writeTimeoutId !== null) { clearTimeout(this.writeTimeoutId); this.writeTimeoutId = null; }
    // Cancel the MTU watchdog — without this it fires 3s after disconnect and
    // calls discoverServices() on a closed client, spurious BleError mid-reconnect.
    clearTimeout(this.mtuTimeoutId);
    this.mtuTimeoutId = -1;
    this.servicesDiscovered = false;
    this.discoveryRetries = 0;
    this.discoveryInFlight = false;
    this.pairChar = null;
    this.not1Char = null;
    this.deviceId = '';
  }

  private discoverServices(): void {
    if (!this.gattClient) {
      // Stale call (e.g. late watchdog after disconnect) — never touch a closed client
      hilog.warn(0x0001, TAG, `[D] SKIP — no gattClient`);
      return;
    }
    if (this.servicesDiscovered) {
      hilog.warn(0x0001, TAG, `[D] SKIP — already discovered`);
      return;
    }
    if (this.discoveryInFlight) {
      // MTU timeout + late BLEMtuChange both call discoverServices(); only one
      // getServices may be in flight, otherwise callbacks interleave and a
      // premature empty/error result kills the whole attempt.
      hilog.warn(0x0001, TAG, `[D] SKIP — request in flight`);
      return;
    }
    if (this.discoveryRetries > 2) {
      hilog.error(0x0001, TAG, `[D] give up after 3 attempts`);
      this.emit(new BleError('Device is not a Nikon camera (PAIR characteristic not found)'));
      return;
    }
    hilog.info(0x0001, TAG, `[D] getServices (attempt ${this.discoveryRetries + 1}/3)`);
    const c = this.gattClient as Object as Record<string, Function>;
    this.discoveryInFlight = true;
    try {
      c['getServices']((err: BusinessError, result: Object) => {
        this.discoveryInFlight = false;
        if (err) {
          // Service discovery can fail transiently on slow links (D5600) —
          // retry before giving up, unless it's the close()-induced stale
          // callback (gattClient already gone by then).
          if (this.discoveryRetries < 2 && this.gattClient) {
            this.discoveryRetries++;
            hilog.warn(0x0001, TAG, `[D] ERR ${err.code} — retrying (${this.discoveryRetries}/2)`);
            setTimeout(() => { this.discoverServices(); }, 2000);
            return;
          }
          hilog.error(0x0001, TAG, `[D] ERR ${err.code}`);
          this.emit(new BleError(`Service discovery failed: ${err.message}`));
          return;
        }
        const arr = Array.isArray(result) ? result as Object[] : ((result as Record<string, Object>)['services'] as Object[]) ?? [];
        hilog.info(0x0001, TAG, `[D] ${arr.length} svcs`);
        for (let i = 0; i < arr.length; i++) {
          const svc = arr[i] as Record<string, Object>;
          hilog.info(0x0001, TAG, `[D] svc[${i}] ${svc['serviceUuid']}`);
          const chars = svc['characteristics'] as Object[];
          if (chars) for (let j = 0; j < chars.length; j++) {
            const ch = chars[j] as Record<string, Object>;
            const u = (ch['characteristicUuid'] as string ?? '').toUpperCase();
            if (u === PAIR.toUpperCase()) this.pairChar = ch;
            else if (u === NOT1.toUpperCase()) this.not1Char = ch;
          }
        }
        hilog.info(0x0001, TAG, `[D] chars pair=${!!this.pairChar} not1=${!!this.not1Char}`);
        if (!this.pairChar) {
          // D-series bodies can return an empty/incomplete service list while
          // the link is still settling (observed: D5600 → 0 svcs on first call).
          // Retry a couple of times before declaring the device unsupported.
          if (this.discoveryRetries < 2) {
            this.discoveryRetries++;
            hilog.warn(0x0001, TAG, `[D] No PAIR characteristic — retrying (${this.discoveryRetries}/2)`);
            setTimeout(() => { this.discoverServices(); }, 2000);
            return;
          }
          hilog.error(0x0001, TAG, `[D] No PAIR characteristic — not a Nikon camera`);
          this.emit(new BleError('Device is not a Nikon camera (PAIR characteristic not found)'));
          return;
        }
        this.servicesDiscovered = true;
        this.emit(new BleServicesDiscovered());
      });
    } catch (e) { hilog.error(0x0001, TAG, `[D] EXC ${JSON.stringify(e)}`); }
  }

  prepare(onDone: () => void): void {
    const pairObj = (this.pairChar ?? this.obj(PAIR)) as Record<string, Object>;
    const not1Obj = (this.not1Char ?? this.obj(NOT1)) as ble.BLECharacteristic;
    const c = this.gattClient as Object as Record<string, Function>;

    // Step 1: PAIR CCN (register callback, may fail for indication-only chars)
    c['setCharacteristicChangeNotification'](pairObj, true, (err: BusinessError) => {
      hilog.info(0x0001, TAG, err ? `[P] PAIR CCN ERR ${err.code}` : `[P] PAIR CCN OK`);
      // Delay to let BLE stack settle before next operation
      setTimeout(() => {
        if (!this.gattClient) return; // cancelled mid-chain — abort silently
        // Step 2: PAIR CCCD descriptor (0x02 = indication)
        const cccdBuf = new ArrayBuffer(2);
        const cccdV = new Uint8Array(cccdBuf);
        cccdV[0] = 0x02; cccdV[1] = 0x00;
        const descObj: Record<string, Object> = {
          'serviceUuid': SVC,
          'characteristicUuid': PAIR,
          'descriptorUuid': '00002902-0000-1000-8000-00805F9B34FB',
          'descriptorValue': cccdBuf,
        };
        c['writeDescriptorValue'](descObj, (err2: BusinessError) => {
          hilog.info(0x0001, TAG, err2 ? `[P] PAIR desc ERR ${err2.code}` : `[P] PAIR desc OK`);
          setTimeout(() => {
            if (!this.gattClient) return; // cancelled mid-chain — abort silently
            // Step 3: NOT1 notification
            c['setCharacteristicChangeNotification'](not1Obj, true, (err3: BusinessError) => {
              hilog.info(0x0001, TAG, err3 ? `[P] NOT1 ERR ${err3.code}` : `[P] NOT1 OK`);
              setTimeout(() => {
                if (!this.gattClient) return; // cancelled mid-chain — abort silently
                // Step 4: NOT2 notification (Linux POC enables this too)
                // Older bodies (D5600) may lack NOT2 entirely — a synchronous
                // throw here would stall prepare() forever, so guard it and
                // always proceed to onDone().
                const not2Obj: ble.BLECharacteristic = { serviceUuid: SVC, characteristicUuid: NOT2, characteristicValue: new ArrayBuffer(1), descriptors: [] };
                try {
                  c['setCharacteristicChangeNotification'](not2Obj, true, (err4: BusinessError) => {
                    hilog.info(0x0001, TAG, err4 ? `[P] NOT2 ERR ${err4.code}` : `[P] NOT2 OK`);
                    hilog.info(0x0001, TAG, `[P] done`);
                    onDone();
                  });
                } catch (e) {
                  hilog.warn(0x0001, TAG, `[P] NOT2 EXC — proceeding anyway: ${JSON.stringify(e)}`);
                  hilog.info(0x0001, TAG, `[P] done`);
                  onDone();
                }
              }, 200);
            });
          }, 200);
        });
      }, 200);
    });
  }

  writePairMessage(data: Uint8Array): void { this.w(PAIR, data); }
  writeId(data: Uint8Array): void { this.w(ID, data); }
  writeTime(data: Uint8Array): void { this.w(TIME, data); }
  writeGeo(data: Uint8Array): void { this.w(GEO, data); }

  getDeviceId(): string { return this.deviceId; }
  isConnected(): boolean { return this.gattClient !== null; }

  private w(uuid: string, data: Uint8Array): void {
    if (this.writeBusy) {
      // Newest-wins one-slot buffer: a stale TIME payload is worthless, a
      // fresh GEO is more valuable — overwrite the slot instead of dropping
      // the frame or queueing more than one write.
      const pending = new PendingWrite();
      pending.uuid = uuid;
      pending.data = data;
      this.pendingWrite = pending;
      hilog.warn(0x0001, TAG, `[W] QUEUED ${uuid} — write in progress`);
      return;
    }
    if (!this.gattClient) return; // torn down (cancel) — never touch a closed client
    this.send(uuid, data);
  }

  // Sends a single write. The caller guarantees the write slot is free
  // (writeBusy === false) — send() itself must NOT re-check the busy gate.
  private send(uuid: string, data: Uint8Array): void {
    const client = this.gattClient; // identity check against stale callbacks
    if (client === null) return; // torn down (cancel) — never touch a closed client
    const seq = ++this.writeSeq; // token for THIS write — stale callbacks get ignored
    this.writeBusy = true;
    hilog.info(0x0001, TAG, `[W] ${uuid} ${data.byteLength}B`);
    const buf = new ArrayBuffer(data.byteLength);
    const v = new Uint8Array(buf);
    for (let i = 0; i < data.byteLength; i++) v[i] = data[i];
    const obj: ble.BLECharacteristic = { serviceUuid: SVC, characteristicUuid: uuid, characteristicValue: buf, descriptors: [] };
    const c = client as Object as Record<string, Function>;

    // Safety timeout: if callback never fires (e.g. camera stopped responding
    // while the link appears alive), count it. Only after consecutive timeouts
    // surface it as a link-loss signal so the service can tear down and
    // reconnect — a single slow write must not look like a dead camera.
    this.writeTimeoutId = setTimeout(() => {
      if (seq !== this.writeSeq) return; // superseded by a newer write — ignore
      if (this.gattClient !== client) return; // connection replaced — ignore
      this.writeTimeoutId = null;
      this.writeBusy = false;
      this.writeTimeoutStreak++;
      hilog.warn(0x0001, TAG, `[W] TIMEOUT #${this.writeTimeoutStreak} reset writeBusy for ${uuid}`);
      if (this.writeTimeoutStreak >= 3) {
        this.writeTimeoutStreak = 0;
        this.emit(new BleError(`Write timeout: ${uuid}`));
        return;
      }
      if (this.pendingWrite !== null) {
        if (this.gattClient !== null) {
          const pending = this.pendingWrite;
          this.pendingWrite = null;
          this.send(pending.uuid, pending.data);
        } else {
          this.pendingWrite = null; // connection torn down — drop silently
        }
      }
    }, 10000);

    c['writeCharacteristicValue'](obj, 1, (err: BusinessError) => {
      if (seq !== this.writeSeq) return; // stale callback for a superseded write — must NOT clear a newer write's timer or release its busy
      if (this.gattClient !== client) return; // stale callback from previous connection
      if (this.writeTimeoutId !== null) {
        clearTimeout(this.writeTimeoutId);
        this.writeTimeoutId = null;
      }
      this.writeBusy = false;
      this.writeTimeoutStreak = 0; // the stack responded — not a timeout
      if (err) {
        // A GEO write failure is the strongest signal of "camera rejected the
        // GPS payload" (reference doc: ATT 0x80 = camera rejecting GPS).
        // HarmonyOS does NOT surface the raw ATT 0x80 (it maps to generic
        // 2900099 etc.), so flag the GEO uuid to make it visible in logs.
        if (uuid === GEO) {
          hilog.warn(0x0001, TAG, `[W] ERR GEO ${err.code}: ${err.message} — camera may reject GPS`);
        } else {
          hilog.error(0x0001, TAG, `[W] ERR ${uuid} ${err.code}: ${err.message}`);
        }
        this.emit(new BleError(`Write ${uuid}: ${err.message}`));
      }
      else { hilog.info(0x0001, TAG, `[W] OK`); this.emit(new BleWriteDone(uuid, 0)); }
      // Flush the buffered (newest-wins) write now that the slot is free.
      if (this.pendingWrite !== null) {
        if (this.gattClient !== null) {
          const pending = this.pendingWrite;
          this.pendingWrite = null;
          this.send(pending.uuid, pending.data);
        } else {
          this.pendingWrite = null; // connection torn down — drop silently
        }
      }
    });
  }

  private obj(uuid: string): ble.BLECharacteristic {
    return { serviceUuid: SVC, characteristicUuid: uuid, characteristicValue: new ArrayBuffer(1), descriptors: [] };
  }

  private emit(event: BleEvent): void { if (this.listener) this.listener(event); }
}

function toUint8Array(v: Uint8Array | ArrayBuffer | undefined | null): Uint8Array {
  if (!v) return new Uint8Array();
  if (v instanceof Uint8Array) return v;
  return new Uint8Array(v as ArrayBuffer);
}
