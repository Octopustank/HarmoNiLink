/**
 * ConnectionPage.ets — Connection status, GPS, & paired device management
 *
 * MessagesCommonView pattern (requires HdsNavigation ancestor).
 * WlanSection card pattern for paired device list.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cameraService, ConnectionState } from '../service/CameraService';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';
import { HdsNavDestination, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

const TAG = 'HarmoNikon-ConnectionPage';

@Component
export struct ConnectionPage {
  @State state: ConnectionState = ConnectionState.Idle;
  @State statusMsg: string = '';
  @State serial: string = '';
  @State step: number = 0;
  @State savedCameras: PairedCamera[] = [];
  @State logMessages: string[] = [];
  @State showLogs: boolean = false;
  @State titleSub: string = '';
  // GPS data mirrored as @State so ArkUI detects changes
  @State gpsLat: string = '--';
  @State gpsLon: string = '--';
  @State gpsAlt: string = '--';
  @State gpsSats: string = '--';
  @State gpsHasFix: boolean = false;
  @State gpsTime: string = '--';
  private scroller: Scroller = new Scroller();
  private gpsTimer: number = -1;

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] ConnectionPage aboutToAppear');
    this.loadSavedCameras();
    cameraService.setStateListener((s: ConnectionState, msg: string) => {
      this.state = s; this.statusMsg = msg;
      this.serial = cameraService.getCameraSerial();
      this.step = cameraService.getPairingStep();
      this.titleSub = s === ConnectionState.Ready ? `已连接 · ${this.serial || 'Camera'}` : '';
      this.logMessages = [...this.logMessages.slice(-49),
        `[${new Date().toLocaleTimeString()}] ${s}: ${msg}`];
    });
    // Poll GPS data independently — state listener only fires on connection changes
    this.gpsTimer = setInterval(() => { this.syncGps(); }, 1000);
  }

  aboutToDisappear(): void {
    if (this.gpsTimer !== -1) { clearInterval(this.gpsTimer); this.gpsTimer = -1; }
  }

  private syncGps(): void {
    const gps = cameraService.gpsData;
    this.gpsLat = gps.latitude.toFixed(6);
    this.gpsLon = gps.longitude.toFixed(6);
    this.gpsAlt = `${gps.altitude.toFixed(1)} m`;
    this.gpsSats = `${gps.satellites}`;
    this.gpsHasFix = gps.hasFix;
    this.gpsTime = gps.lastUpdateTime;
  }

  private async loadSavedCameras(): Promise<void> {
    try { this.savedCameras = await cameraService.getSavedCameras(); }
    catch (e) { hilog.warn(0x0001, TAG, `loadSavedCameras err: ${JSON.stringify(e)}`); }
  }

  private onReconnect(cam: PairedCamera): void { cameraService.connectToSavedCamera(cam); }
  private async onForget(cam: PairedCamera): Promise<void> {
    try { await cameraService.removeCamera(cam.name); await this.loadSavedCameras(); }
    catch (e) { hilog.warn(0x0001, TAG, `Forget err: ${JSON.stringify(e)}`); }
  }
  private onDisconnect(): void { cameraService.disconnect(); }

  private getStateColor(): string {
    if (this.state === ConnectionState.Ready) return '#34C759';
    if (this.state === ConnectionState.Error) return '#FF3B30';
    if (this.state === ConnectionState.Idle) return '#99000000';
    return '#FF9500';
  }
  private getStateLabel(): string {
    if (this.state === ConnectionState.Ready) return '已连接';
    if (this.state === ConnectionState.Error) return '连接错误';
    if (this.state === ConnectionState.Idle) return '未连接';
    if (this.state === ConnectionState.Scanning) return '扫描中';
    if (this.state === ConnectionState.Connecting) return '连接中';
    if (this.state === ConnectionState.Discovering) return '发现服务';
    if (this.state === ConnectionState.Pairing) return `配对中 (${this.step}/6)`;
    if (this.state === ConnectionState.Bonding) return '绑定中';
    return this.state;
  }

  @Builder statusCard() {
    Column() {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 }).fill(this.getStateColor())
        Text(this.getStateLabel()).fontSize(13).fontColor(this.getStateColor())
      }.margin({ bottom: 8 })
      if (this.serial) Text(this.serial).fontSize(15).fontColor('#E6000000').fontWeight(FontWeight.Medium).margin({ bottom: 4 })
      if (this.statusMsg) Text(this.statusMsg).fontSize(13).fontColor('#99000000').maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .borderRadius(16).backgroundColor('#FFFFFF')
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
  }

  @Builder gpsCard() {
    Column() {
      Text('GPS 信息').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#E6000000').width('100%').margin({ bottom: 10 })
      GpsRow({ label: '纬度', value: this.gpsLat })
      GpsRow({ label: '经度', value: this.gpsLon })
      GpsRow({ label: '海拔', value: this.gpsAlt })
      GpsRow({ label: '卫星数', value: this.gpsSats })
      GpsRow({ label: '定位', value: this.gpsHasFix ? '已定位' : '未定位' })
      GpsRow({ label: '更新时间', value: this.gpsTime })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .borderRadius(16).backgroundColor('#FFFFFF')
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
  }

  @Builder savedDevicesSection() {
    Column() {
      Text('已配对设备').fontSize(14).fontColor('#99000000')
        .margin({ left: 12, bottom: 8, top: 28 }).alignSelf(ItemAlign.Start).fontWeight(500)
      if (this.savedCameras.length > 0) {
        Column() {
          ForEach(this.savedCameras, (cam: PairedCamera, i: number) => {
            Row() {
              Text(cam.name).fontSize(16).fontWeight(500).fontColor('#E6000000')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Row({ space: 8 }) {
                Button('连接').fontSize(12).fontWeight(FontWeight.Medium).height(32).borderRadius(16)
                  .backgroundColor('#007DFF').fontColor(Color.White).padding({ left: 16, right: 16 })
                  .onClick(() => { this.onReconnect(cam); })
                Button('删除').fontSize(12).fontWeight(FontWeight.Medium).height(32).borderRadius(16)
                  .backgroundColor('#FF3B30').fontColor(Color.White).padding({ left: 16, right: 16 })
                  .onClick(() => { this.onForget(cam); })
              }
            }.width('100%').height(48).padding({ left: 8, right: 8 })
            if (i < this.savedCameras.length - 1) {
              Divider().strokeWidth(0.5).color('#1A000000').margin({ left: 8, right: 8 })
            }
          }, (cam: PairedCamera, i: number) => cam.name + i)
        }
        .width('100%').backgroundColor('#FFFFFF').borderRadius(16).padding(4)
        .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
      } else {
        Column() { Text('暂无已配对设备').fontSize(13).fontColor('#99000000').textAlign(TextAlign.Center) }
        .width('100%').height(48).backgroundColor('#FFFFFF').borderRadius(16)
        .padding({ left: 8, right: 8 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder logSection() {
    Column() {
      Row() {
        Text('日志').fontSize(16).fontWeight(FontWeight.Medium).fontColor('#E6000000'); Blank()
        Text(this.showLogs ? '收起' : '展开').fontSize(13).fontColor('#007DFF')
      }.width('100%').onClick(() => { this.showLogs = !this.showLogs; })
      if (this.showLogs) {
        Column() {
          if (this.logMessages.length > 0) {
            ForEach(this.logMessages.slice(-20), (msg: string) => {
              Text(msg).fontSize(10).fontColor('#99000000').width('100%').padding({ top: 1, bottom: 1 })
            })
          } else { Text('暂无日志').fontSize(12).fontColor('#99000000').padding({ top: 8 }) }
        }.width('100%').margin({ top: 8 })
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 16, bottom: 16 })
    .borderRadius(16).backgroundColor('#FFFFFF')
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
  }

  build() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column({ space: 16 }) {
          Blank().height(56)

          this.statusCard()
          if (this.state === ConnectionState.Ready) { this.gpsCard() }
          if (this.state === ConnectionState.Ready) {
            Button('断开连接').fontSize(14).fontWeight(FontWeight.Medium).height(40).borderRadius(20)
              .backgroundColor('#FF3B30').fontColor(Color.White).padding({ left: 36, right: 36 })
              .onClick(() => { this.onDisconnect(); })
          }
          this.savedDevicesSection()
          this.logSection()
        }
        .padding({ left: 16, right: 16, bottom: 56 })
      }
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .backgroundColor('#F1F3F5')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .titleBar({
      content: { title: { mainTitle: '连接', subTitle: this.titleSub || undefined } },
      style: {
        scrollEffectOpts: { scrollEffectType: ScrollEffectType.GRADIENT_BLUR },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        },
      },
    })
    .hideBackButton(true)
  }
}

@Component
struct GpsRow {
  @Prop label: string = '';
  @Prop value: string = '--';
  build() {
    Row() {
      Text(this.label).fontSize(13).fontColor('#99000000').width(64)
      Text(this.value).fontSize(13).fontColor('#E6000000').layoutWeight(1)
    }.width('100%').padding({ top: 2, bottom: 2 })
  }
}
