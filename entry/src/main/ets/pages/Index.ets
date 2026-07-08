/**
 * Index.ets — Main page for HarmoNiLink
 *
 * Minimal functional UI for testing:
 *   - Scan button + discovered cameras list
 *   - Saved cameras list + connect/remove
 *   - State display
 *   - Manual GPS send button
 *   - Log display (last 50 messages)
 *
 * [CHECKPOINT] All actions logged to both UI and HiLog.
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { CameraService, ConnectionState } from '../service/CameraService';
import { GpsData } from '../service/GpsData';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';
import { DiscoveredCamera } from '../ble/BleScanner';

const TAG = 'HarmoNiLink-Index';

@Entry
@Component
struct Index {
  @State stateText: string = 'Idle';
  @State statusMessage: string = 'Ready.';
  @State stateColor: string = '#999999';
  @State stepText: string = '';
  @State serialText: string = '';
  @State logMessages: string[] = ['[BOOT] NiLink started.'];
  @State discoveredCameras: DiscoveredCamera[] = [];
  @State savedCameras: PairedCamera[] = [];
  @State isScanning: boolean = false;
  @State gpsDisplay: string = 'Waiting for GPS...';

  private cameraService: CameraService = new CameraService();
  private scanTimeoutId: number = -1;

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] Index.aboutToAppear()');

    const ctx = getContext(this) as common.UIAbilityContext;
    this.cameraService.setContext(ctx);

    // Wire state listener
    this.cameraService.setStateListener((state: ConnectionState, message: string) => {
      this.stateText = state;
      this.statusMessage = message;
      this.stepText = `Step: ${this.cameraService.getPairingStep()}`;
      this.serialText = this.cameraService.getCameraSerial() ?
        `Serial: ${this.cameraService.getCameraSerial()}` : '';

      switch (state) {
        case ConnectionState.Ready: this.stateColor = '#00AA00'; break;
        case ConnectionState.Error: this.stateColor = '#FF0000'; break;
        case ConnectionState.Bonding: this.stateColor = '#FF8800'; break;
        case ConnectionState.Connecting: this.stateColor = '#0066FF'; break;
        case ConnectionState.Discovering: this.stateColor = '#0066FF'; break;
        case ConnectionState.Pairing: this.stateColor = '#0066FF'; break;
        case ConnectionState.Scanning: this.stateColor = '#0066FF'; break;
        default: this.stateColor = '#999999'; break;
      }

      if (state === ConnectionState.Ready) {
        // Refresh saved cameras after pairing/bonding
        this.loadSavedCameras();
      }

      this.addLog(`[STATE] ${state}: ${message}`);
      this.refreshGpsDisplay();
    });

    // Load saved cameras after init completes (small delay for async store init)
    setTimeout(() => { this.loadSavedCameras(); }, 500);

    // Poll GPS display every 2 seconds
    setInterval(() => { this.refreshGpsDisplay(); }, 2000);
  }

  build() {
    Column() {
      // Header
      Text('NiLink')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 16, bottom: 4 })

      Text('Nikon Smart GPS Provider')
        .fontSize(12)
        .fontColor('#888888')
        .margin({ bottom: 8 })

      // State indicator
      Row() {
        Text(this.stateText)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.stateColor)
        Blank()
        Text(this.stepText).fontSize(12).fontColor('#888888')
      }
      .width('100%')
      .padding({ left: 16, right: 16 })

      Text(this.statusMessage)
        .fontSize(13)
        .fontColor('#555555')
        .width('100%')
        .padding({ left: 16, right: 16 })
        .margin({ bottom: 4 })

      if (this.serialText) {
        Text(this.serialText).fontSize(12).fontColor('#00AA00').padding({ left: 16, right: 16 })
      }

      // GPS data display
      Text(`GPS: ${this.gpsDisplay}`).fontSize(13).fontColor('#0066CC')
        .width('100%').padding({ left: 16, right: 16 }).margin({ top: 2 })

      Divider().margin({ top: 8, bottom: 8 })

      // Action buttons
      Row({ space: 8 }) {
        Button('Scan')
          .fontSize(14)
          .onClick(() => { this.onScan(); })
          .enabled(!this.isScanning)

        Button('Stop')
          .fontSize(14)
          .onClick(() => { this.onStopScan(); })
          .enabled(this.isScanning)

        Button('Disconnect')
          .fontSize(14)
          .onClick(() => { this.onDisconnect(); })

        Button('Send GPS')
          .fontSize(14)
          .onClick(() => { this.onSendFakeGeo(); })
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
      .margin({ bottom: 8 })

      // Discovered cameras (during scan)
      if (this.isScanning || this.discoveredCameras.length > 0) {
        Text('Discovered:').fontSize(14).fontWeight(FontWeight.Medium)
          .alignSelf(ItemAlign.Start).padding({ left: 16, right: 16 })

        List() {
          ForEach(this.discoveredCameras, (cam: DiscoveredCamera, index: number) => {
            ListItem() {
              Row() {
                Column() {
                  Text(cam.deviceName).fontSize(14)
                  Text(`RSSI: ${cam.rssi}`).fontSize(11).fontColor('#888888')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Button('Pair')
                  .fontSize(12)
                  .onClick(() => { this.onSelectCamera(cam); })
              }
              .width('100%')
              .padding({ left: 16, right: 8, top: 8, bottom: 8 })
            }
          }, (cam: DiscoveredCamera) => cam.deviceId)
        }
        .height(120)
        .backgroundColor('#F0F0F0')
        .margin({ bottom: 8 })
      }

      // Saved cameras (always visible)
      Text('Saved Cameras:').fontSize(14).fontWeight(FontWeight.Medium)
        .alignSelf(ItemAlign.Start).padding({ left: 16, right: 16 })

      if (this.savedCameras.length > 0) {
        List() {
          ForEach(this.savedCameras, (cam: PairedCamera, index: number) => {
            ListItem() {
              Row() {
                Column() {
                  Text(cam.name).fontSize(14)
                  Text(`Addr: ${cam.address}`).fontSize(10).fontColor('#888888')
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Button('Reconnect')
                  .fontSize(11)
                  .onClick(() => { this.onReconnect(cam); })
                Button('Forget')
                  .fontSize(11)
                  .fontColor('#FF0000')
                  .onClick(() => { this.onForget(cam); })
              }
              .width('100%')
              .padding({ left: 16, right: 8, top: 8, bottom: 8 })
            }
          }, (cam: PairedCamera) => cam.name)
        }
        .height(120)
        .backgroundColor('#F0F0F0')
        .margin({ bottom: 8 })
      } else {
        Text('  (no paired cameras)').fontSize(12).fontColor('#AAAAAA')
          .alignSelf(ItemAlign.Start).padding({ left: 16, right: 16 }).margin({ bottom: 8 })
      }

      Divider()

      // Log area
      Text('Log:').fontSize(14).fontWeight(FontWeight.Medium)
        .alignSelf(ItemAlign.Start).padding({ left: 16, right: 16, top: 4 })

      List() {
        ForEach(this.logMessages, (msg: string, index: number) => {
          ListItem() {
            Text(msg)
              .fontSize(11)
              .fontColor('#333333')
              .padding({ left: 16, right: 16, top: 2, bottom: 2 })
          }
        }, (_msg: string, index: number) => `${index}`)
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#FAFAFA')
    }
    .width('100%')
    .height('100%')
  }

  // ==================== Actions ====================

  private onScan(): void {
    this.addLog('[ACTION] Starting scan...');
    this.isScanning = true;
    this.discoveredCameras = [];
    this.cameraService.startScan();

    // Poll discovered cameras during scan
    const pollId = setInterval(() => {
      if (!this.isScanning) {
        clearInterval(pollId);
        return;
      }
      const list = this.cameraService.getDiscoveredCameras();
      if (list.length > 0) {
        this.discoveredCameras = list;
      }
    }, 500);

    // Auto-stop scan after 15 seconds
    clearTimeout(this.scanTimeoutId);
    this.scanTimeoutId = setTimeout(() => {
      clearInterval(pollId);
      if (this.isScanning) {
        this.onStopScan();
        this.addLog('[ACTION] Scan timeout (15s)');
      }
    }, 15000);
  }

  private onStopScan(): void {
    this.addLog('[ACTION] Stopping scan');
    this.isScanning = false;
    this.cameraService.stopScan();
    clearTimeout(this.scanTimeoutId);
  }

  private onSelectCamera(cam: DiscoveredCamera): void {
    this.addLog(`[ACTION] Connecting to ${cam.deviceName}...`);
    this.onStopScan();
    this.cameraService.selectDiscoveredCamera(cam);
  }

  private onReconnect(cam: PairedCamera): void {
    this.addLog(`[ACTION] Reconnecting to ${cam.name}...`);
    this.cameraService.connectToSavedCamera(cam);
  }

  private onDisconnect(): void {
    this.addLog('[ACTION] Disconnecting...');
    this.cameraService.disconnect();
  }

  private onSendFakeGeo(): void {
    this.addLog('[ACTION] Sending fake GPS...');
    this.cameraService.sendFakeGeo();
  }

  private async onForget(cam: PairedCamera): Promise<void> {
    this.addLog(`[ACTION] Forgetting camera: ${cam.name}`);
    await this.cameraService.removeCamera(cam.name);
    await this.loadSavedCameras();
  }

  private async loadSavedCameras(): Promise<void> {
    try {
      this.savedCameras = await this.cameraService.getSavedCameras();
      this.addLog(`[INIT] Loaded ${this.savedCameras.length} saved cameras`);
    } catch (err) {
      hilog.error(0x0001, TAG, `loadSavedCameras ERROR: ${JSON.stringify(err)}`);
    }
  }

  private addLog(msg: string): void {
    hilog.info(0x0001, TAG, msg);
    this.logMessages = [...this.logMessages, msg];
    if (this.logMessages.length > 50) {
      this.logMessages = this.logMessages.slice(-50);
    }
  }

  private refreshGpsDisplay(): void {
    const gps = this.cameraService.gpsData;
    if (gps.hasFix) {
      this.gpsDisplay = `${gps.latitude.toFixed(6)}, ${gps.longitude.toFixed(6)} ±${gps.altitude}m @ ${gps.lastUpdateTime}`;
    } else if (this.stateText === 'Ready') {
      this.gpsDisplay = 'Acquiring GPS...';
    } else {
      this.gpsDisplay = 'Connect camera first';
    }
  }
}
