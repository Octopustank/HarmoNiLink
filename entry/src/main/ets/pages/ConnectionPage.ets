/**
 * ConnectionPage.ets — Connection status, GPS, & paired device management
 *
 * Phase 1: per-camera status cards. Each paired camera shows its own state
 * (from CameraStateEvent) and its own connect/disconnect/forget buttons,
 * replacing the single global status card.
 *
 * MessagesCommonView pattern (requires HdsNavigation ancestor).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager } from '@kit.AbilityKit';
import { cameraService, ConnectionState, CameraStateEvent } from '../service/CameraService';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';
import { HdsNavDestination, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-ConnectionPage';

/** Per-camera live state, updated from CameraStateEvent. */
interface CameraStatus {
  name: string;
  state: ConnectionState;
  message: string;
}

@Component
export struct ConnectionPage {
  @State savedCameras: PairedCamera[] = [];
  @State cameraStatuses: CameraStatus[] = [];
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
  @State controllerName: string = ''; // per-install name shown on the camera
  @State reconnectEnabled: boolean = false; // 保持连接 — mirrored from cameraService
  private scroller: Scroller = new Scroller();
  private gpsTimer: number = -1;
  private offStateListener: (() => void) | null = null;

  private isPairingOwner(): boolean { return this.owner === 'pairing'; }
  private isConnectionOwner(): boolean { return this.owner === 'connection'; }

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] ConnectionPage aboutToAppear');
    this.loadAppVersion();
    this.loadSavedCameras();
    this.controllerName = cameraService.getControllerName();
    this.reconnectEnabled = cameraService.isReconnectEnabled();
    this.offStateListener = cameraService.setStateListener((event: CameraStateEvent) => {
      // Sync owner first — all derived helpers depend on @State reactivity
      this.owner = cameraService.getOwner();
      if (event.cameraName !== '') {
        this.updateCameraStatus(event.cameraName, event.state, event.message);
      }
      this.logMessages = [...this.logMessages.slice(-49),
        `[${new Date().toLocaleTimeString()}] [${event.cameraName || '全局'}] ${event.state}: ${event.message}`];
      // Title bar subtitle — show progress only for our own operations
      if (this.isPairingOwner()) {
        this.titleSub = '配对页操作中';
      } else if (event.cameraName !== '' && (event.state === ConnectionState.Scanning
        || event.state === ConnectionState.Connecting || event.state === ConnectionState.Discovering
        || event.state === ConnectionState.Pairing || event.state === ConnectionState.Bonding)) {
        this.titleSub = `正在连接 ${event.cameraName}…`;
      } else {
        this.titleSub = '';
      }
      if (event.state === ConnectionState.Ready || event.state === ConnectionState.Idle) {
        this.loadSavedCameras();
      }
    });
    this.gpsTimer = setInterval(() => { this.syncGps(); }, 1000);
  }

  aboutToDisappear(): void {
    if (this.gpsTimer !== -1) { clearInterval(this.gpsTimer); this.gpsTimer = -1; }
    if (this.offStateListener) { this.offStateListener(); this.offStateListener = null; }
  }

  private updateCameraStatus(name: string, state: ConnectionState, message: string): void {
    const next = this.cameraStatuses.map((c) =>
      c.name === name ? { name, state, message } as CameraStatus : c);
    const found = this.cameraStatuses.some((c) => c.name === name);
    this.cameraStatuses = found ? next : [...this.cameraStatuses, { name, state, message } as CameraStatus];
  }

  private getCameraStatus(name: string): CameraStatus | undefined {
    return this.cameraStatuses.find((c) => c.name === name);
  }

  private hasReadyCamera(): boolean {
    return this.cameraStatuses.some((c) => c.state === ConnectionState.Ready);
  }

  private syncGps(): void {
    const gps = cameraService.gpsData;
    this.gpsLat = gps.latitude.toFixed(6);
    this.gpsLon = gps.longitude.toFixed(6);
    this.gpsAlt = `${gps.altitude.toFixed(1)} m`;
    this.gpsSats = gps.satellites >= 0 ? `${gps.satellites}` : '--';
    this.gpsHasFix = gps.hasFix;
    this.gpsTime = gps.lastUpdateTime;
    // Keep the toggle in sync with the service (e.g. prefs loaded after page shows)
    const en = cameraService.isReconnectEnabled();
    if (en !== this.reconnectEnabled) this.reconnectEnabled = en;
  }

  private onReconnectToggle(on: boolean): void {
    if (on) {
      // One-time explanation the first time the user enables 保持连接
      if (!cameraService.wasReconnectPrompted()) {
        cameraService.markReconnectPrompted();
        this.getUIContext().getPromptAction().showDialog({
          title: '保持连接',
          message: '开启后，连接断开时将自动持续重连（含后台），直到相机恢复或您手动断开。\n\n持续重连会保持蓝牙与定位后台任务运行，可能增加耗电。',
          buttons: [{ text: '知道了', color: $r('app.color.brand') }]
        }).catch((e: Error) => {
          hilog.warn(0x0001, TAG, `Reconnect hint dialog err: ${e.message}`);
        });
      }
    }
    this.reconnectEnabled = on;
    cameraService.setReconnectEnabled(on);
  }

  private async loadSavedCameras(): Promise<void> {
    try { this.savedCameras = await cameraService.getSavedCameras(); }
    catch (e) { hilog.warn(0x0001, TAG, `loadSavedCameras err: ${JSON.stringify(e)}`); }
  }

  private loadAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      this.appVersion = `NiLink v${info.versionName}`;
    } catch (e) {
      this.appVersion = '';
    }
  }

  private onReconnect(cam: PairedCamera): void {
    // Pairing is serial (classic bonding needs the radio exclusively) — block
    // new connections while the pairing tab owns the resource.
    if (this.isPairingOwner()) return;
    if (cameraService.isCameraConnected(cam.name)) return;
    // Connection cap guard — refuse with a hint before starting the flow.
    if (!cameraService.canConnectMore()) {
      this.getUIContext().getPromptAction().showToast({
        message: `已达连接上限（${cameraService.getConnectedCount()} 台），请先断开其他相机`, duration: 2500
      });
      return;
    }
    // Reconnect also needs BLE + location permissions — request on demand
    cameraService.requestPermissionsIfNeeded().then((granted: boolean) => {
      if (!granted) {
        this.getUIContext().getPromptAction().showToast({ message: '需要蓝牙和位置权限才能连接', duration: 2500 });
        return;
      }
      // One-time hint on first connect: camera "关闭时发送" + 保持连接
      if (!cameraService.wasConnectHintShown()) {
        cameraService.markConnectHintShown();
        this.getUIContext().getPromptAction().showDialog({
          title: '连接提示',
          message: '为获得稳定连接，推荐：\n\n1. 在相机设置中开启「关闭时发送」——相机休眠/关机后仍保持连接，本 App 可自动重连。\n\n2. 开启本页的「保持连接」开关——连接意外断开时自动持续重连，直到相机恢复。',
          buttons: [{ text: '继续连接', color: $r('app.color.brand') }]
        }).then(() => { cameraService.startReconnect(cam); }).catch((e: Error) => {
          hilog.warn(0x0001, TAG, `Connect hint dialog err: ${e.message}`);
        });
      } else {
        cameraService.startReconnect(cam);
      }
    });
  }

  private onDisconnectCamera(cam: PairedCamera): void {
    cameraService.disconnect(cam.name);
  }

  private onForget(cam: PairedCamera): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除已配对设备',
      message: `确定删除「${cam.name}」？\n\n删除后需同时在系统蓝牙设置和相机端清除配对信息，否则可能无法重新连接。`,
      buttons: [
        { text: '取消', color: $r('app.color.brand') },
        { text: '删除', color: $r('app.color.danger') }
      ]
    }).then((result) => {
      if (result.index === 1) {
        // Disconnect first if this camera is connected
        if (cameraService.isCameraConnected(cam.name)) {
          cameraService.disconnect(cam.name);
        }
        cameraService.removeCamera(cam.name).then(() => this.loadSavedCameras())
          .catch((e: Error) => hilog.warn(0x0001, TAG, `Forget err: ${e.message}`));
      }
    }).catch((err: Error) => {
      hilog.warn(0x0001, TAG, `Forget dialog err: ${err.message}`);
    });
  }

  private stateColor(state: ConnectionState): ResourceColor {
    if (state === ConnectionState.Ready) return $r('app.color.success');
    if (state === ConnectionState.Error) return $r('app.color.danger');
    if (state === ConnectionState.Idle) return $r('app.color.text_secondary');
    return $r('app.color.warning');
  }

  private stateLabel(state: ConnectionState): string {
    if (state === ConnectionState.Ready) return '已连接';
    if (state === ConnectionState.Error) return '连接错误';
    if (state === ConnectionState.Idle) return '未连接';
    if (state === ConnectionState.Scanning) return '扫描中';
    if (state === ConnectionState.Connecting) return '连接中';
    if (state === ConnectionState.Discovering) return '发现服务';
    if (state === ConnectionState.Pairing) return '配对中';
    if (state === ConnectionState.Bonding) return '绑定中';
    return state;
  }

  private cameraBusy(state: ConnectionState): boolean {
    return state === ConnectionState.Scanning || state === ConnectionState.Connecting
      || state === ConnectionState.Discovering || state === ConnectionState.Pairing
      || state === ConnectionState.Bonding;
  }

  @Builder pairingNotice() {
    Column() {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.warning'))
        Text('配对页正在进行设备配对，连接操作已暂停').fontSize(13).fontColor($r('app.color.warning'))
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: 12 })
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
              Column() {
                Text(cam.name).fontSize(16).fontWeight(500).fontColor($r('app.color.text_primary'))
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                Row({ space: 6 }) {
                  Circle({ width: 6, height: 6 }).fill(this.stateColor(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle))
                  Text(this.stateLabel(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle))
                    .fontSize(11).fontColor(this.stateColor(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle))
                }.margin({ top: 3 })
              }.layoutWeight(1).alignItems(HorizontalAlign.Start)
              Row({ space: 8 }) {
                Button(this.cameraBusy(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle)
                  || this.getCameraStatus(cam.name)?.state === ConnectionState.Ready
                  ? '断开' : '连接')
                  .fontSize(12).fontWeight(FontWeight.Medium).height(32).borderRadius(16)
                  .backgroundColor(this.getCameraStatus(cam.name)?.state === ConnectionState.Ready
                    || this.cameraBusy(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle)
                    ? $r('app.color.danger') : $r('app.color.brand')).fontColor(Color.White)
                  .padding({ left: 16, right: 16 })
                  .enabled(!this.isPairingOwner())
                  .onClick(() => {
                    const st = this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle;
                    if (st === ConnectionState.Ready || this.cameraBusy(st)) {
                      this.onDisconnectCamera(cam);
                    } else {
                      this.onReconnect(cam);
                    }
                  })
                Button('删除')
                  .fontSize(12).fontWeight(FontWeight.Medium).height(32).borderRadius(16)
                  .backgroundColor(this.cameraBusy(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle)
                    || this.isPairingOwner()
                    ? $r('app.color.text_secondary') : $r('app.color.danger')).fontColor(Color.White)
                  .padding({ left: 16, right: 16 })
                  .enabled(!this.cameraBusy(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle) && !this.isPairingOwner())
                  .onClick(() => { this.onForget(cam); })
              }
            }.width('100%').padding({ left: 8, right: 8, top: 10, bottom: 10 }).alignItems(VerticalAlign.Center)
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

          if (this.isPairingOwner()) { this.pairingNotice() }
          Row() {
            Column() {
              Text('保持连接').fontSize(14).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
              Text('断开后自动持续重连，直到相机恢复或手动断开').fontSize(11)
                .fontColor($r('app.color.text_secondary')).margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.reconnectEnabled })
              .onChange((on: boolean) => { this.onReconnectToggle(on); })
          }
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(16).backgroundColor($r('app.color.card_background'))
          .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
          .margin({ top: 12 })
          if (this.hasReadyCamera()) { this.gpsCard() }

          Text('相机开启「关闭时发送」选项后，连接始终自动保持。\n需要后台下发数据，请在系统设置中允许始终定位。')
            .fontSize(11).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Center).padding({ left: 4, right: 4 })
            .margin({ top: 12 })
            .lineHeight(16)

          Text(`本设备配对名称：${this.controllerName}`)
            .fontSize(11).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Center).padding({ left: 4, right: 4 })
            .margin({ top: 10 })

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
