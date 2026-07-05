import { ble } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  BleConnected, BleDisconnected, BleServicesDiscovered,
  BleMtuChanged, BlePairIndication, BleNot1Notification,
  BleWriteDone, BleError, BleEvent
} from './BleEvent';

const TAG = 'HarmoNikon-BleClient';

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
  private servicesDiscovered: boolean = false; // prevent duplicate discovery
  private mtuTimeoutId: number = -1; // cancel MTU timeout when response arrives

  connect(deviceId: string, listener: BleListener): void {
    hilog.info(0x0001, TAG, `[C] ${deviceId}`);
    this.deviceId = deviceId;
    this.listener = listener;
    this.pairChar = this.not1Char = null;
    this.servicesDiscovered = false;
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
                hilog.warn(0x0001, TAG, `[M] updateConnectionParam fail: ${e.message}`);
              });
            }
          } catch (e) {}
          try { this.gattClient?.setBLEMtuSize(517); hilog.info(0x0001, TAG, `[M] setMTU`); } catch (e) {}
          // MTU timeout: if no response in 3s, proceed anyway
          clearTimeout(this.mtuTimeoutId);
          this.mtuTimeoutId = setTimeout(() => {
            hilog.warn(0x0001, TAG, `[M] MTU timeout — discovering anyway`);
            this.discoverServices();
          }, 3000);
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
    try { this.gattClient?.disconnect(); this.gattClient?.close(); } catch (e) {}
    this.gattClient = null;
  }

  private discoverServices(): void {
    if (this.servicesDiscovered) {
      hilog.warn(0x0001, TAG, `[D] SKIP — already discovered`);
      return;
    }
    hilog.info(0x0001, TAG, `[D] getServices`);
    const c = this.gattClient as Object as Record<string, Function>;
    try {
      c['getServices']((err: BusinessError, result: Object) => {
        if (err) { hilog.error(0x0001, TAG, `[D] ERR ${err.code}`); return; }
        this.servicesDiscovered = true;
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
            // Step 3: NOT1 notification
            c['setCharacteristicChangeNotification'](not1Obj, true, (err3: BusinessError) => {
              hilog.info(0x0001, TAG, err3 ? `[P] NOT1 ERR ${err3.code}` : `[P] NOT1 OK`);
              setTimeout(() => {
                // Step 4: NOT2 notification (Linux POC enables this too)
                const not2Obj: ble.BLECharacteristic = { serviceUuid: SVC, characteristicUuid: NOT2, characteristicValue: new ArrayBuffer(1), descriptors: [] };
                c['setCharacteristicChangeNotification'](not2Obj, true, (err4: BusinessError) => {
                  hilog.info(0x0001, TAG, err4 ? `[P] NOT2 ERR ${err4.code}` : `[P] NOT2 OK`);
                  hilog.info(0x0001, TAG, `[P] done`);
                  onDone();
                });
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
      hilog.warn(0x0001, TAG, `[W] SKIP ${uuid} — write in progress`);
      return;
    }
    this.writeBusy = true;
    hilog.info(0x0001, TAG, `[W] ${uuid} ${data.byteLength}B`);
    const buf = new ArrayBuffer(data.byteLength);
    const v = new Uint8Array(buf);
    for (let i = 0; i < data.byteLength; i++) v[i] = data[i];
    const obj: ble.BLECharacteristic = { serviceUuid: SVC, characteristicUuid: uuid, characteristicValue: buf, descriptors: [] };
    const c = this.gattClient as Object as Record<string, Function>;
    c['writeCharacteristicValue'](obj, 1, (err: BusinessError) => {
      this.writeBusy = false;
      if (err) { hilog.error(0x0001, TAG, `[W] ERR ${err.code}: ${err.message}`); this.emit(new BleError(`Write: ${err.message}`)); }
      else { hilog.info(0x0001, TAG, `[W] OK`); this.emit(new BleWriteDone(uuid, 0)); }
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
