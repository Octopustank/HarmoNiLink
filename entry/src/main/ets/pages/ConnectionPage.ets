/**
 * ConnectionPage.ets — Connection status, GPS, & paired device management
 *
 * MessagesCommonView pattern (requires HdsNavigation ancestor).
 * WlanSection card pattern for paired device list.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { bundleManager } from '@kit.AbilityKit';
import { cameraService, ConnectionState } from '../service/CameraService';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';
import { HdsNavDestination, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-ConnectionPage';

@Component
export struct ConnectionPage {
  @State state: ConnectionState = ConnectionState.Idle;
  @State statusMsg: string = '';
  @State serial: string = '';
  @State step: number = 0;
  @State savedCameras: PairedCamera[] = [];
  @State logMessages: string[] = [];
  @State showLogs: boolean = false;
  // GPS data mirrored as @State so ArkUI detects changes
  @State gpsLat: string = '--';
  @State gpsLon: string = '--';
  @State gpsAlt: string = '--';
  @State gpsSats: string = '--';
  @State gpsHasFix: boolean = false;
  @State gpsTime: string = '--';
  @State appVersion: string = '';
  @State titleSub: string = '';
  @State owner: string = 'none'; // synced from cameraService — drives @State re-render
  private scroller: Scroller = new Scroller();
  private gpsTimer: number = -1;

  // True when cancel button should show: any active ownership, not Ready
  private showCancel(): boolean { return this.owner !== 'none' && this.state !== ConnectionState.Ready; }

  // True when an operation is actively in progress (scan/connect/pair/bond)
  private isInProgress(): boolean {
    const s = this.state;
    return s === ConnectionState.Scanning || s === ConnectionState.Connecting
      || s === ConnectionState.Discovering || s === ConnectionState.Pairing
      || s === ConnectionState.Bonding;
  }
  // True when any tab owns the resource — blocks starting new operations
  private isBlocked(): boolean { return this.owner !== 'none'; }
  private isConnectionOwner(): boolean { return this.owner === 'connection'; }
  private isPairingOwner(): boolean { return this.owner === 'pairing'; }

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] ConnectionPage aboutToAppear');
    this.loadAppVersion();
    this.loadSavedCameras();
    cameraService.setStateListener((s: ConnectionState, msg: string) => {
      // Sync owner first — all derived helpers depend on @State reactivity
      this.owner = cameraService.getOwner();
      this.state = s;
      // When pairing tab owns the operation, show neutral status
      this.statusMsg = this.isPairingOwner() ? '配对进行中…' : msg;
      this.serial = cameraService.getCameraSerial();
      this.step = cameraService.getPairingStep();
      if (s === ConnectionState.Ready || s === ConnectionState.Idle) { this.loadSavedCameras(); }
      this.logMessages = [...this.logMessages.slice(-49),
        `[${new Date().toLocaleTimeString()}] ${s}: ${msg}`];
      // Title bar subtitle — show progress only for our own operations
      if (this.isPairingOwner()) {
        this.titleSub = '配对页操作中';
      } else if (s === ConnectionState.Idle) { this.titleSub = ''; }
      else if (s === ConnectionState.Scanning) { this.titleSub = '正在扫描设备…'; }
      else if (s === ConnectionState.Connecting) { this.titleSub = '正在连接…'; }
      else if (s === ConnectionState.Discovering) { this.titleSub = '正在发现服务…'; }
      else if (s === ConnectionState.Pairing) { this.titleSub = `正在进行安全握手 (${this.step}/4)…`; }
      else if (s === ConnectionState.Bonding) { this.titleSub = '正在完成绑定…'; }
      else if (s === ConnectionState.Ready) { this.titleSub = ''; }
      else if (s === ConnectionState.Error) { this.titleSub = ''; }
    });
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

  private loadAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.appVersion = `HarmoNiLink v${info.versionName}`;
    } catch (e) {
      this.appVersion = '';
    }
  }

  private onReconnect(cam: PairedCamera): void {
    if (this.isBlocked()) return;
    cameraService.startReconnect(cam);
  }

  private onForget(cam: PairedCamera): void {
    if (this.isInProgress()) return;
    const dialog = promptAction.showDialog({
      title: '删除已配对设备',
      message: `确定删除「${cam.name}」？\n\n删除后需同时在系统蓝牙设置和相机端清除配对信息，否则可能无法重新连接。`,
      buttons: [
        { text: '取消', color: $r('app.color.brand') },
        { text: '删除', color: $r('app.color.danger') }
      ]
    });
    dialog.then((result) => {
      if (result.index === 1) {
        // Disconnect first if this camera is connected
        if (cameraService.getCameraSerial() === cam.name) {
          cameraService.disconnect();
        }
        cameraService.removeCamera(cam.name).then(() => this.loadSavedCameras())
          .catch((e: Error) => hilog.warn(0x0001, TAG, `Forget err: ${e.message}`));
      }
    });
  }

  private onDisconnect(): void { cameraService.disconnect(); }

  private getStateColor(): ResourceColor {
    if (this.state === ConnectionState.Ready) return $r('app.color.success');
    if (this.state === ConnectionState.Error) return $r('app.color.danger');
    if (this.state === ConnectionState.Idle) return $r('app.color.text_secondary');
    return $r('app.color.warning');
  }
  private getStateLabel(): string {
    if (this.isPairingOwner() && this.state !== ConnectionState.Idle
      && this.state !== ConnectionState.Ready && this.state !== ConnectionState.Error) {
      return '配对页操作中';
    }
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
      }
      if (this.serial) {
        Text(this.serial).fontSize(15).fontColor($r('app.color.text_primary'))
          .fontWeight(FontWeight.Medium).margin({ top: 6 })
      }
      if (this.isPairingOwner()) {
        Text('配对页正在进行设备配对，请稍候…').fontSize(13)
          .fontColor($r('app.color.text_secondary')).maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 6 })
      } else if (this.statusMsg) {
        Text(this.statusMsg).fontSize(13).fontColor($r('app.color.text_secondary'))
          .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 6 })
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
  }

  @Builder gpsCard() {
    Column() {
      Text('GPS 信息').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).width('100%').margin({ bottom: 10 })
      GpsRow({ label: '纬度', value: this.gpsLat })
      GpsRow({ label: '经度', value: this.gpsLon })
      GpsRow({ label: '海拔', value: this.gpsAlt })
      GpsRow({ label: '卫星数', value: this.gpsSats })
      GpsRow({ label: '定位', value: this.gpsHasFix ? '已定位' : '未定位' })
      GpsRow({ label: '更新时间', value: this.gpsTime })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ top: 12 })
  }

  @Builder savedDevicesSection() {
    Column() {
      Text('已配对设备').fontSize(14).fontColor($r('app.color.text_secondary'))
        .margin({ left: 12, bottom: 8, top: 28 }).alignSelf(ItemAlign.Start).fontWeight(500)
      if (this.savedCameras.length > 0) {
        Column() {
          ForEach(this.savedCameras, (cam: PairedCamera, i: number) => {
            Row() {
              Text(cam.name).fontSize(16).fontWeight(500).fontColor($r('app.color.text_primary'))
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
              Row({ space: 8 }) {
                Button(this.isBlocked() ? '…' : '连接')
                  .fontSize(12).fontWeight(FontWeight.Medium).height(32).borderRadius(16)
                  .backgroundColor(this.isBlocked() ? $r('app.color.text_secondary') : $r('app.color.brand')).fontColor(Color.White)
                  .padding({ left: 16, right: 16 })
                  .enabled(!this.isBlocked())
                  .onClick(() => { this.onReconnect(cam); })
                Button('删除')
                  .fontSize(12).fontWeight(FontWeight.Medium).height(32).borderRadius(16)
                  .backgroundColor(this.isInProgress() || this.isPairingOwner()
                    ? $r('app.color.text_secondary') : $r('app.color.danger')).fontColor(Color.White)
                  .padding({ left: 16, right: 16 })
                  .enabled(!this.isInProgress() && !this.isPairingOwner())
                  .onClick(() => { this.onForget(cam); })
              }
            }.width('100%').height(48).padding({ left: 8, right: 8 })
            if (i < this.savedCameras.length - 1) {
              Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 8, right: 8 })
            }
          }, (cam: PairedCamera, i: number) => cam.name + i)
        }
        .width('100%').backgroundColor($r('app.color.card_background')).borderRadius(16).padding(4)
        .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
      } else {
        Column() { Text('暂无已配对设备').fontSize(13).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center) }
        .width('100%').height(48).justifyContent(FlexAlign.Center).backgroundColor($r('app.color.card_background')).borderRadius(16)
        .padding({ left: 8, right: 8 })
      }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }

  @Builder logSection() {
    Column() {
      Row() {
        Text('日志').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')); Blank()
        Text(this.showLogs ? '收起' : '展开').fontSize(13).fontColor($r('app.color.brand'))
      }.width('100%').onClick(() => { this.showLogs = !this.showLogs; })
      if (this.showLogs) {
        Column() {
          if (this.logMessages.length > 0) {
            ForEach(this.logMessages.slice(-20), (msg: string) => {
              Text(msg).fontSize(10).fontColor($r('app.color.text_secondary')).width('100%').padding({ top: 1, bottom: 1 })
            })
          } else { Text('暂无日志').fontSize(12).fontColor($r('app.color.text_secondary')).padding({ top: 8 }) }
          if (this.appVersion) {
            Text(this.appVersion).fontSize(11).fontColor($r('app.color.text_secondary'))
              .width('100%').textAlign(TextAlign.Center).padding({ top: 8 })
          }
        }.width('100%').margin({ top: 8 })
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ top: 12 })
  }

  build() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column() {
          Blank().height(56)

          this.statusCard()
          if (this.state === ConnectionState.Ready) { this.gpsCard() }
          if (this.showCancel()) {
            Button('取消').fontSize(14).fontWeight(FontWeight.Medium).height(40).borderRadius(20)
              .backgroundColor($r('app.color.warning')).fontColor(Color.White).padding({ left: 36, right: 36 })
              .margin({ top: 12 })
              .onClick(() => { cameraService.disconnect(); })
          } else if (this.state === ConnectionState.Ready) {
            Button('断开连接').fontSize(14).fontWeight(FontWeight.Medium).height(40).borderRadius(20)
              .backgroundColor($r('app.color.danger')).fontColor(Color.White).padding({ left: 36, right: 36 })
              .margin({ top: 12 })
              .onClick(() => { this.onDisconnect(); })
          }

          Text('Tips：相机休眠时保持 BLE 连接，GPS 可持续传输。\n若连接意外中断，App 将自动重试恢复，无需干预。')
            .fontSize(11).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Center).padding({ left: 4, right: 4 })
            .margin({ top: 12 })
            .lineHeight(16)

          this.savedDevicesSection()
          Text('找不到相机？请前往「配对」页面搜索设备')
            .fontSize(13).fontColor($r('app.color.text_secondary'))
            .textAlign(TextAlign.Center).width('100%').padding({ top: 4, bottom: 4 })
            .margin({ top: 12 })
          this.logSection()
          Blank().layoutWeight(1)
        }
        .padding({ left: 16, right: 16, bottom: 56 })
      }
      .height('100%')
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .backgroundColor($r('app.color.page_background'))
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
      Text(this.label).fontSize(13).fontColor($r('app.color.text_secondary')).width(64)
      Text(this.value).fontSize(13).fontColor($r('app.color.text_primary')).layoutWeight(1)
    }.width('100%').padding({ top: 2, bottom: 2 })
  }
}
