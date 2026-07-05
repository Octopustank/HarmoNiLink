import { ble, connection } from '@kit.ConnectivityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'HarmoNiLink-BleScanner';

export interface DiscoveredCamera {
  deviceId: string; deviceName: string; rssi: number;
  hasManufacturerData: boolean; isConnectable: boolean;
}
export type ScanListener = (cameras: DiscoveredCamera[]) => void;

export class BleScanner {
  private scanListener: ScanListener | null = null;
  private discoveredCameras: Map<string, DiscoveredCamera> = new Map();
  private isScanning: boolean = false;
  private bleScanner: ble.BleScanner | null = null;

  startScan(listener: ScanListener): void {
    hilog.info(0x0001, TAG, `=== startScan() ===`);
    this.scanListener = listener;
    this.discoveredCameras.clear();
    this.isScanning = true;

    // Self-test: check Bluetooth state
    this.selfTest();

    // All three APIs in parallel
    this.tryClassicDiscovery();
    this.tryNewBleApi();
    this.tryOldBleApi();
  }

  private selfTest(): void {
    hilog.info(0x0001, TAG, `--- SELF-TEST ---`);
    try {
      const wasDiscovering = connection.isBluetoothDiscovering();
      hilog.info(0x0001, TAG, `  isBluetoothDiscovering: ${wasDiscovering}`);
    } catch (e) {
      hilog.info(0x0001, TAG, `  isBluetoothDiscovering threw: ${JSON.stringify(e)}`);
    }
    hilog.info(0x0001, TAG, `--- SELF-TEST DONE ---`);
  }

  private tryClassicDiscovery(): void {
    hilog.info(0x0001, TAG, `[CLASSIC] starting...`);
    try {
      connection.on('bluetoothDeviceFind', (data: Object) => {
        const arr = data as string[];
        hilog.info(0x0001, TAG, `[CLASSIC v17] FIRED! ${arr.length} devices: [${arr.join(', ')}]`);
        for (let i = 0; i < arr.length; i++) {
          this.add(arr[i], `BT-device-${i}`, 0);
        }
      });

      connection.on('discoveryResult', (data: Object) => {
        const arr = data as Object[];
        hilog.info(0x0001, TAG, `[CLASSIC v18] FIRED! ${arr.length} results`);
        for (let i = 0; i < arr.length; i++) {
          const d = arr[i] as Record<string, Object>;
          this.add(
            (d['deviceId'] as string) ?? '',
            (d['deviceName'] as string) ?? `BT-${i}`,
            (d['rssi'] as number) ?? 0
          );
        }
      });

      const wasDiscovering = connection.isBluetoothDiscovering();
      hilog.info(0x0001, TAG, `[CLASSIC] wasDiscovering=${wasDiscovering}`);

      if (!wasDiscovering) {
        connection.startBluetoothDiscovery();
        hilog.info(0x0001, TAG, `[CLASSIC] startBluetoothDiscovery() called`);
      }

      // Check after 1 second if discovery actually started
      setTimeout(() => {
        const nowDiscovering = connection.isBluetoothDiscovering();
        hilog.info(0x0001, TAG, `[CLASSIC] after 1s: isDiscovering=${nowDiscovering}`);
        if (!nowDiscovering) {
          hilog.error(0x0001, TAG, `[CLASSIC] DISCOVERY DID NOT START!`);
        }
      }, 1000);

    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0001, TAG, `[CLASSIC] FAILED: ${e.code} ${e.message}`);
    }
  }

  private tryNewBleApi(): void {
    try {
      this.bleScanner = ble.createBleScanner();
      this.bleScanner.on('BLEDeviceFind', (report: Object) => {
        const r = report as Record<string, Object>;
        // NEW API ScanReport structure: {reportType, scanResult: {deviceId, deviceName, rssi, ...}}
        const inner = r['scanResult'];
        if (inner) {
          const sr = inner as Record<string, Object>;
          const id = (sr['deviceId'] as string) ?? '';
          const name = (sr['deviceName'] as string) ?? '';
          const rssi = (sr['rssi'] as number) ?? 0;
          hilog.info(0x0001, TAG, `[NEW BLE] nested: id=${id} name='${name}' rssi=${rssi} keys=[${Object.keys(sr).join(',')}]`);
          this.add(id, name, rssi);
        } else {
          hilog.info(0x0001, TAG, `[NEW BLE] no scanResult in report, keys=[${Object.keys(r).join(',')}]`);
        }
      });
      const opts: ble.ScanOptions = {
        interval: 100, dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      };
      this.bleScanner.startScan(null, opts);
      hilog.info(0x0001, TAG, `[NEW BLE] startScan(null) OK`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0001, TAG, `[NEW BLE] FAILED: ${e.code} ${e.message}`);
    }
  }

  private tryOldBleApi(): void {
    try {
      ble.on('BLEDeviceFind', (results: Object) => {
        const arr = results as Object[];
        hilog.info(0x0001, TAG,
          `[OLD BLE] FIRED! ${arr.length} results`);
        for (let i = 0; i < arr.length; i++) {
          const r = arr[i] as Record<string, Object>;
          const id = (r['deviceId'] as string) ?? '';
          const name = (r['deviceName'] as string) ?? '';
          const rssi = (r['rssi'] as number) ?? 0;
          // If no deviceId at top level, check for nested data
          if (!id || !name) {
            const data = r['data'];
            hilog.info(0x0001, TAG,
              `[OLD BLE] result[${i}] keys=[${Object.keys(r).join(',')}] dataLen=${data ? (data as ArrayBuffer).byteLength : 0}`);
          } else {
            hilog.info(0x0001, TAG,
              `[OLD BLE] result[${i}]: id=${id} name='${name}' rssi=${rssi}`);
          }
          this.add(id, name, rssi);
        }
      });
      const opts: ble.ScanOptions = {
        interval: 100, dutyMode: ble.ScanDuty.SCAN_MODE_LOW_LATENCY,
        matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE,
      };
      ble.startBLEScan(null, opts);
      hilog.info(0x0001, TAG, `[OLD BLE] startBLEScan(null) OK`);
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0001, TAG, `[OLD BLE] FAILED: ${e.code} ${e.message}`);
    }
  }

  stopScan(): void {
    this.isScanning = false;
    try { connection.stopBluetoothDiscovery(); } catch (e) {}
    try { connection.off('bluetoothDeviceFind'); } catch (e) {}
    try { connection.off('discoveryResult'); } catch (e) {}
    try { this.bleScanner?.stopScan(); this.bleScanner?.off('BLEDeviceFind'); } catch (e) {}
    this.bleScanner = null;
    try { ble.stopBLEScan(); ble.off('BLEDeviceFind'); } catch (e) {}
  }

  private add(deviceId: string, deviceName: string, rssi: number): void {
    if (!deviceId || !this.isScanning) return;
    if (this.discoveredCameras.has(deviceId)) return;
    hilog.info(0x0001, TAG, `[ADD] id=${deviceId} name='${deviceName}' rssi=${rssi}`);
    this.discoveredCameras.set(deviceId, {
      deviceId, deviceName: deviceName || deviceId, rssi,
      hasManufacturerData: false, isConnectable: false,
    });
    if (this.scanListener) {
      this.scanListener(Array.from(this.discoveredCameras.values()));
    }
  }
}
