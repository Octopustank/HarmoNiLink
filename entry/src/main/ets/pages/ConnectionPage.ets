/**
 * ConnectionPage.ets — Connection status, GPS, & paired device management
 *
 * Phase 3: per-camera "连接开关" (connection toggle, ON by default = connect +
 * auto-reconnect until switched off) replaces the old connect/disconnect
 * buttons and the global keep-alive toggle. Deleting a camera is a standard
 * HDS swipe-left action (trash icon / swipe-through).
 *
 * MessagesCommonView pattern (requires HdsNavigation ancestor).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { bundleManager, common } from '@kit.AbilityKit';
import { SymbolGlyphModifier, promptAction } from '@kit.ArkUI';
import { cameraService, ConnectionState, CameraStateEvent } from '../service/CameraService';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';
import { SlaCell, SlaSev } from '../data/SlaTracker';
import { HdsNavDestination, ScrollEffectType, hdsMaterial, HdsListItem } from '@kit.UIDesignKit';
import { commentManager } from '@kit.AppGalleryKit';

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
  @State showSheet: boolean = false; // 半模态 sheet（关于 / 设备信息）— 单实例，避免两个 bindSheet 互相干扰
  @State sheetKind: string = 'about'; // 'about' | 'info'
  @State infoCameraName: string = ''; // the camera whose SLA is shown
  @State slaCells: SlaCell[] = []; // materialized snapshot (frozen at open)
  @State slaTooltip: string = ''; // tooltip text for the tapped cell
  @State slaTooltipIndex: number = -1; // tapped cell index (-1 = none)
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
  // Bumped ONLY when a toggle must visually snap back after a refused flip.
  // Part of the ForEach key: normal list reloads keep keys stable so toggles
  // are NOT recreated (recreation in the same frame as the touch kills the
  // switch animation and can desync the visual from the persisted flag).
  @State revertTick: number = 0;
  private scroller: Scroller = new Scroller();
  private gpsTimer: number = -1;
  private offStateListener: (() => void) | null = null;

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] ConnectionPage aboutToAppear');
    this.loadAppVersion();
    this.loadSavedCameras();
    this.controllerName = cameraService.getControllerName();
    this.offStateListener = cameraService.setStateListener((event: CameraStateEvent) => {
      // Sync owner first — all derived helpers depend on @State reactivity
      this.owner = cameraService.getOwner();
      if (event.cameraName !== '') {
        this.updateCameraStatus(event.cameraName, event.state, event.message);
      }
      this.logMessages = [...this.logMessages.slice(-49),
        `[${new Date().toLocaleTimeString()}] [${event.cameraName || '全局'}] ${event.state}: ${event.message}`];
      // Title bar subtitle — show progress only for our own operations
      if (cameraService.isPairingBonding()) {
        this.titleSub = '正在经典蓝牙绑定';
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
    // prefs init is async — the first loadSavedCameras() may see an empty
    // cache. Re-read once it has certainly settled (also triggers reconcile).
    setTimeout(() => { this.loadSavedCameras(); }, 1500);
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

  private syncGps(): void {
    const gps = cameraService.gpsData;
    this.gpsLat = gps.latitude.toFixed(6);
    this.gpsLon = gps.longitude.toFixed(6);
    this.gpsAlt = `${gps.altitude.toFixed(1)} m`;
    this.gpsSats = gps.satellites >= 0 ? `${gps.satellites}` : '--';
    this.gpsHasFix = gps.hasFix;
    this.gpsTime = gps.lastUpdateTime;
  }

  /**
   * Per-camera connection toggle (Phase 3). ON = connect and keep reconnecting
   * until switched off; OFF = disconnect and stop reconnecting.
   */
  private onConnectToggle(cam: PairedCamera, on: boolean): void {
    if (on) {
      if (cameraService.isPairingBonding()) {
        // Classic bonding holds the radio exclusively — defer a new connect.
        // (A pairing scan/handshake runs in parallel, so only bonding blocks.)
        this.getUIContext().getPromptAction().showToast({ message: '正在经典蓝牙绑定，请稍后再开启连接', duration: 2000 });
        this.revertToggle();
        return;
      }
      // Already connected/connecting — just persist the intent.
      if (cameraService.isCameraConnected(cam.name) || cameraService.isCameraBusy(cam.name)) {
        cameraService.setKeepAlive(cam.name, true);
        return;
      }
      if (!cameraService.canConnectMore()) {
        this.getUIContext().getPromptAction().showToast({
          message: `已达连接上限（${cameraService.getConnectedCount()} 台），请先关闭其他相机的连接开关`, duration: 2500
        });
        this.revertToggle();
        return;
      }
      // Beyond the field-tested count: warn (dismissable), then connect.
      // "不再提示" persists the dismissal; plain "继续" warns again next time.
      if (cameraService.shouldWarnMultiCam()) {
        this.getUIContext().getPromptAction().showDialog({
          title: '连接更多设备',
          message: '连接更多设备不保证稳定性，且可能增加耗电。',
          buttons: [
            { text: '不再提示', color: $r('app.color.text_secondary') },
            { text: '继续', color: $r('app.color.brand') }
          ]
        }).then((result) => {
          if (result.index === 0) {
            cameraService.markMultiCamWarned();
          }
          this.startPendingConnect(cam);
        }).catch((e: Error) => {
          hilog.warn(0x0001, TAG, `Multi-cam warn dialog err: ${e.message}`);
          this.startPendingConnect(cam); // dialog failed — don't block the user
        });
        return;
      }
      this.startPendingConnect(cam);
    } else {
      // OFF: stop auto-reconnect, then drop the link if one exists.
      cameraService.setKeepAlive(cam.name, false);
      if (cameraService.isCameraConnected(cam.name) || cameraService.isCameraBusy(cam.name)) {
        cameraService.disconnect(cam.name);
      }
    }
  }

  /**
   * Persist the ON intent and run the connect chain: permissions → (one-time
   * first-connect hint dialog) → startReconnect. Every async continuation
   * re-checks the persisted flag so flipping the toggle OFF mid-flight aborts
   * the chain (ghost guard), while a fresh ON never aborts itself.
   */
  private startPendingConnect(cam: PairedCamera): void {
    cameraService.setKeepAlive(cam.name, true);
    // Connecting needs BLE + location permissions — request on demand
    cameraService.requestPermissionsIfNeeded().then((granted: boolean) => {
      // Ghost guard: turned OFF while this chain was in flight — abort.
      if (!cameraService.isKeepAlive(cam.name)) return;
      if (!granted) {
        this.getUIContext().getPromptAction().showToast({ message: '需要蓝牙和位置权限才能连接', duration: 2500 });
        cameraService.setKeepAlive(cam.name, false);
        this.revertToggle();
        return;
      }
      // One-time hint on first connect: camera "关闭时发送" + auto-reconnect
      if (!cameraService.wasConnectHintShown()) {
        cameraService.markConnectHintShown();
        this.getUIContext().getPromptAction().showDialog({
          title: '连接提示',
          message: '为获得稳定连接，推荐：\n\n1. 在相机设置中开启「关闭时发送」——相机休眠/关机后仍保持连接，本 App 可自动重连。\n\n2. 确保定位权限设为「始终允许」——应用在后台时才能持续下发 GPS。',
          buttons: [{ text: '继续连接', color: $r('app.color.brand') }]
        }).then(() => {
          // Re-check after the dialog too — it can stay up for a long time.
          if (cameraService.isKeepAlive(cam.name)) {
            cameraService.startReconnect(cam);
          }
        }).catch((e: Error) => {
          hilog.warn(0x0001, TAG, `Connect hint dialog err: ${e.message}`);
        });
      } else {
        cameraService.startReconnect(cam);
      }
    });
  }

  /** A toggle was refused — bump the key so it visually snaps back to the
   * persisted flag (the only case where a toggle must be recreated). */
  private revertToggle(): void {
    this.revertTick++;
  }

  /**
   * Keep-alive cameras that are neither connected, connecting, NOR waiting in
   * the reconnect backoff get their connection started (app start / page
   * revisit / after prefs settle). A camera sitting out a backoff window owns
   * its own retry schedule — restarting it here would bypass the backoff and
   * make unrelated events (another camera's cancel, pairing completion) fire
   * connects at random-looking moments.
   */
  private reconcileConnections(): void {
    if (cameraService.isPairingBonding()) return; // only classic bonding blocks
    for (const cam of this.savedCameras) {
      if (!cam.keepAlive) continue;
      if (cameraService.isCameraConnected(cam.name) || cameraService.isCameraBusy(cam.name)) continue;
      if (cameraService.isCameraReconnectPending(cam.name)) continue; // backoff owns it
      if (!cameraService.canConnectMore()) break; // cap reached — stop here
      cameraService.startReconnect(cam); // service re-checks cap/owner internally
    }
  }

  private async loadSavedCameras(): Promise<void> {
    try {
      const cams = await cameraService.getSavedCameras();
      this.savedCameras = cams.slice(); // new array ref so ForEach re-diffs
      this.reconcileConnections();
    }
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
        // removeCamera() aborts any in-flight connect/pair itself (no ghost
        // connection keeps running after the record is gone).
        cameraService.removeCamera(cam.name).then(() => this.loadSavedCameras())
          .catch((e: Error) => hilog.warn(0x0001, TAG, `Forget err: ${e.message}`));
      }
    }).catch((err: Error) => {
      hilog.warn(0x0001, TAG, `Forget dialog err: ${err.message}`);
    });
  }

  /** Open the SLA/device-info half-modal — freeze the materialized snapshot
   * BEFORE flipping the sheet. Never read getSlaTimeline inside a @Builder:
   * the state listener re-runs it and shifts the 2h window. */
  private onShowInfo(cam: PairedCamera): void {
    this.infoCameraName = cam.name;
    // Synchronous first pass — if this tracker never loaded (first open after
    // app start), this is empty; the await below re-materializes once the disk
    // read settles and refreshes @State, so the FIRST open already shows data.
    this.slaCells = cameraService.getSlaTimeline(cam.name);
    this.slaTooltip = '';
    this.slaTooltipIndex = -1;
    this.sheetKind = 'info';
    this.showSheet = true;
    const name = cam.name;
    cameraService.getSlaTimelineLoaded(name).then((cells: SlaCell[]): void => {
      // Guard: only refresh if this sheet is still open on the SAME camera.
      if (this.sheetKind === 'info' && this.infoCameraName === name) {
        this.slaCells = cells;
      }
    });
  }

  private openAboutSheet(): void {
    this.sheetKind = 'about';
    this.showSheet = true;
  }

  private getInfoCamera(): PairedCamera | undefined {
    return this.savedCameras.find((c) => c.name === this.infoCameraName);
  }

  private slaSevColor(sev: number): ResourceColor {
    if (sev === SlaSev.GREEN) return $r('app.color.success');
    if (sev === SlaSev.YELLOW) return $r('app.color.sla_light');
    if (sev === SlaSev.ORANGE) return $r('app.color.warning');
    if (sev === SlaSev.RED) return $r('app.color.danger');
    return $r('app.color.sla_grey');
  }

  private slaSevLabel(sev: number): string {
    if (sev === SlaSev.GREEN) return '连接正常';
    if (sev === SlaSev.YELLOW) return '偶发断连，数据已送达';
    if (sev === SlaSev.ORANGE) return '存在数据问题（无定位等）';
    if (sev === SlaSev.RED) return '完全中断，无数据';
    return '无下发活动';
  }

  /** Format an epoch-ms timestamp as HH:MM. */
  private slaTimeLabel(ts: number): string {
    const d = new Date(ts);
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private onSlaCellTap(index: number): void {
    if (index < 0 || index >= this.slaCells.length) return;
    const cell = this.slaCells[index];
    this.slaTooltipIndex = index;
    this.slaTooltip = `${this.slaTimeLabel(cell.startTs)}–${this.slaTimeLabel(cell.endTs)} · ${this.slaSevLabel(cell.sev)}`;
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

  /**
   * Status line under the camera name. While the toggle is ON but the link is
   * down (waiting / auto-reconnecting), show the live message instead of a
   * bare "未连接" — the toggle promises a connection, so say where it is.
   */
  private cameraStateText(cam: PairedCamera): string {
    const status = this.getCameraStatus(cam.name);
    const st = status?.state ?? ConnectionState.Idle;
    if (st === ConnectionState.Idle && cam.keepAlive) {
      const msg = status?.message ?? '';
      return msg !== '' ? msg : '待连接';
    }
    return this.stateLabel(st);
  }

  @Builder pairingNotice() {
    Column() {
      Row({ space: 8 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.warning'))
        Text('正在经典蓝牙绑定，连接操作已暂停').fontSize(13).fontColor($r('app.color.warning'))
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ bottom: 12 })
  }

  /** Always-present GPS card — stable layout, no jump on connect/disconnect.
   * The status light is ALWAYS visible (grey = nothing connected, yellow =
   * acquiring / connecting, green = heartbeat running with a fix) and
   * replaces the old 定位 row. */
  @Builder gpsCard() {
    Column() {
      Row() {
        Text('GPS 信息').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Blank()
        Circle({ width: 8, height: 8 }).fill(this.gpsLightColor())
        Text(this.gpsLightLabel()).fontSize(11).fontColor(this.gpsLightColor()).margin({ left: 6 })
      }.width('100%').margin({ bottom: 10 })
      GpsRow({ label: '配对名称', value: this.controllerName })
      Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ top: 4, bottom: 6 })
      GpsRow({ label: '纬度', value: this.gpsLat })
      GpsRow({ label: '经度', value: this.gpsLon })
      GpsRow({ label: '海拔', value: this.gpsAlt })
      GpsRow({ label: '卫星数', value: this.gpsSats })
      GpsRow({ label: '更新时间', value: this.gpsTime })
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ top: 12 })
  }

  private anyCameraReady(): boolean {
    return this.cameraStatuses.some((c) => c.state === ConnectionState.Ready);
  }

  private anyCameraBusy(): boolean {
    return this.cameraStatuses.some((c) => c.state !== ConnectionState.Ready && c.state !== ConnectionState.Idle);
  }

  private gpsLightColor(): ResourceColor {
    if (this.anyCameraReady()) {
      return this.gpsHasFix ? $r('app.color.success') : $r('app.color.warning');
    }
    if (this.anyCameraBusy()) return $r('app.color.warning'); // connecting / acquiring
    return $r('app.color.text_secondary'); // nothing connected — grey
  }

  private gpsLightLabel(): string {
    if (this.anyCameraReady()) {
      return this.gpsHasFix ? '定位下发中' : '正在获取';
    }
    if (this.anyCameraBusy()) return '正在连接';
    return '未连接';
  }

  @Builder savedDevicesSection() {
    Column() {
      Text('已配对设备').fontSize(14).fontColor($r('app.color.text_secondary'))
        .margin({ left: 12, bottom: 8, top: 28 }).alignSelf(ItemAlign.Start).fontWeight(500)
      if (this.savedCameras.length > 0) {
        // One table card: rows separated by dividers inside a single card
        // (swipe-to-delete is per row via HdsListItem).
        Column() {
          List() {
            ForEach(this.savedCameras, (cam: PairedCamera, i: number) => {
              HdsListItem({
                customItemBuilder: (): void => { this.cameraRow(cam, i < this.savedCameras.length - 1); },
                swipeActionOptions: {
                  icons: [
                    {
                      icon: new SymbolGlyphModifier($r('sys.symbol.info_circle'))
                        .fontColor([$r('app.color.card_background')]).fontSize(16),
                      backgroundColor: $r('app.color.text_secondary'),
                      onAction: () => { this.onShowInfo(cam); }
                    }
                  ],
                  deleteIconOptions: {
                    onAction: () => { this.onForget(cam); }
                  },
                  fullDeleteOptions: {
                    isFullDelete: true, // swipe through the card to delete
                    onFullDeleteAction: () => { this.onForget(cam); }
                  }
                }
              })
            }, (cam: PairedCamera) => `${cam.name}_${this.revertTick}`)
          }
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.None)
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

  /** One table row: name + live state on the left, connection toggle on the
   * right; optional trailing divider separates rows inside the shared card. */
  @Builder cameraRow(cam: PairedCamera, withDivider: boolean) {
    Column() {
      Row() {
        Column() {
          Text(cam.name).fontSize(16).fontWeight(500).fontColor($r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Row({ space: 6 }) {
            Circle({ width: 6, height: 6 }).fill(this.stateColor(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle))
            Text(this.cameraStateText(cam))
              .fontSize(11).fontColor(this.stateColor(this.getCameraStatus(cam.name)?.state ?? ConnectionState.Idle))
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          }.margin({ top: 3 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Toggle({ type: ToggleType.Switch, isOn: cam.keepAlive })
        // Always interactive: turning OFF is a cancel and must work even
        // while the pairing tab owns the radio (the ON direction refuses
        // with a toast in onConnectToggle instead of a dead switch).
        .onChange((on: boolean) => { this.onConnectToggle(cam, on); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (withDivider) {
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 12, right: 12 })
      }
    }
  }

  @Builder logSection() {
    Column() {
      // 关于 — settings-style row with chevron (half-modal sheet)
      Row() {
        Text('关于').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18).fontColor([$r('app.color.text_secondary')])
      }
      .width('100%').padding({ left: 12, right: 12, top: 14, bottom: 14 })
      .onClick(() => { this.openAboutSheet(); })

      Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 12, right: 12 })

      // 日志 — collapsible, chevron rotates down when expanded
      Row() {
        Text('日志').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary')).layoutWeight(1)
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18).fontColor([$r('app.color.text_secondary')])
          .rotate({ angle: this.showLogs ? 90 : 0 })
          .animation({ duration: 200, curve: Curve.EaseOut })
      }
      .width('100%').padding({ left: 12, right: 12, top: 14, bottom: 14 })
      .onClick(() => { this.showLogs = !this.showLogs; })

      if (this.showLogs) {
        Column() {
          if (this.logMessages.length > 0) {
            ForEach(this.logMessages.slice(-20), (msg: string) => {
              Text(msg).fontSize(10).fontColor($r('app.color.text_secondary')).width('100%').padding({ top: 1, bottom: 1 })
            })
          } else { Text('暂无日志').fontSize(12).fontColor($r('app.color.text_secondary')).padding({ top: 8 }) }
        }.width('100%').padding({ left: 12, right: 12, bottom: 12 })
      }
    }
    .width('100%').alignItems(HorizontalAlign.Start)
    .padding({ top: 4, bottom: 4 })
    .borderRadius(16).backgroundColor($r('app.color.card_background'))
    .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
    .margin({ top: 12 })
  }

  /** Single bindSheet content dispatcher — one sheet instance serving both the
   * 关于 and 设备信息 sheets. Two chained bindSheet($$...) calls on one node
   * fight over the same show state (点关于不弹、点信息弹关于的错乱). */
  @Builder sheetContent() {
    if (this.sheetKind === 'about') {
      this.aboutSheet()
    } else {
      this.infoSheet()
    }
  }

  /** 设备信息 + SLA 看板 half-modal (bindSheet). */
  @Builder infoSheet() {
    Column() {
      Text('设备信息').fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 36 })

      Column() {
        InfoRow({ label: '名称', value: this.getInfoCamera()?.name ?? this.infoCameraName })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })
        InfoRow({ label: 'BLE 地址', value: this.getInfoCamera()?.address ?? '--' })
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })
        InfoRow({ label: '状态', value: this.stateLabel(this.getCameraStatus(this.infoCameraName)?.state ?? ConnectionState.Idle) })
      }
      .width('100%').borderRadius(16).backgroundColor($r('app.color.card_background'))
      .margin({ top: 24 })

      Column() {
        Text('过去 2 小时连接健康度').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        this.slaTimelineBar()
        Row() {
          Text('2 小时前').fontSize(11).fontColor($r('app.color.text_secondary'))
          Blank()
          Text('现在').fontSize(11).fontColor($r('app.color.text_secondary'))
        }.width('100%').margin({ top: 4 })
        if (this.slaTooltip !== '') {
          Text(this.slaTooltip).fontSize(12).fontColor($r('app.color.text_primary')).margin({ top: 8 })
        }
        this.slaLegend()
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .borderRadius(16).backgroundColor($r('app.color.card_background'))
      .margin({ top: 12 })

      Blank().layoutWeight(1)
    }
    .width('100%').height('100%').padding({ left: 16, right: 16 })
  }

  /** 60-cell static timeline bar (2min per cell over [now-2h, now]). */
  @Builder slaTimelineBar() {
    Row() {
      ForEach(this.slaCells, (cell: SlaCell, i: number) => {
        Column()
          .height(24)
          .layoutWeight(1)
          .backgroundColor(this.slaSevColor(cell.sev))
          .borderRadius(1)
          .margin({ left: 0.5, right: 0.5 })
          .onClick(() => { this.onSlaCellTap(i); })
      }, (cell: SlaCell) => `${cell.startTs}_${cell.sev}`)
    }
    .width('100%')
    .margin({ top: 12 })
  }

  /** 涂色说明 legend. */
  @Builder slaLegend() {
    Column() {
      Row({ space: 6 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.success'))
        Text('连接正常').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.sla_light'))
        Text('偶发断连，但数据已送达').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.warning'))
        Text('存在数据问题（无定位等）').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.danger'))
        Text('完全中断，无数据').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Circle({ width: 8, height: 8 }).fill($r('app.color.sla_grey'))
        Text('无下发活动').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  /** 关于 half-modal (bindSheet) — app icon/name centered, settings-style rows. */
  @Builder aboutSheet() {
    Column() {
      Image($r('app.media.app_icon')).width(72).height(72).borderRadius(18).margin({ top: 36 })
      Text('NiLink').fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 14 })
      Text('HarmoNiLink').fontSize(13).fontColor($r('app.color.text_secondary')).margin({ top: 2 })

      Column() {
        Row() {
          Text('应用版本').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text(this.appVersion).fontSize(14).fontColor($r('app.color.text_secondary'))
        }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })

        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })

        Row() {
          Text('开源协议').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          Text('Mulan PSL v2').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ right: 4 })
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })
        .onClick(() => { this.onAboutLicense(); })

        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })

        Row() {
          Text('开源仓库').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })
        .onClick(() => { this.onAboutRepo(); })

        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })

        Row() {
          Text('做个评价').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })
        .onClick(() => { this.onAboutComment(); })

        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })

        Row() {
          Text('删除连接健康度日志').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })
        .onClick(() => { this.onAboutClearSla(); })

        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })

        Row() {
          Text('重置引导').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
          SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([$r('app.color.text_secondary')])
        }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })
        .onClick(() => { this.onAboutReset(); })
      }
      .width('100%').borderRadius(16).backgroundColor($r('app.color.card_background'))
      .margin({ top: 32, bottom: 24 })

      Blank().layoutWeight(1)
    }
    .width('100%').height('100%').padding({ left: 16, right: 16 })
  }

  private openExternalLink(url: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.openLink(url, { appLinkingOnly: false })
      .then(() => {})
      .catch((e: Error) => { hilog.warn(0x0001, TAG, `openLink fail: ${e.message}`); });
  }

  private onAboutLicense(): void {
    this.openExternalLink('https://license.coscl.org.cn/MulanPSL2');
  }

  private onAboutRepo(): void {
    this.openExternalLink('https://github.com/Octopustank/HarmoNiLink');
  }

  private onAboutComment(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      commentManager.showCommentDialog(ctx).then(() => {}).catch((e: Error) => {
        hilog.warn(0x0001, TAG, `showCommentDialog fail: ${e.message}`);
      });
    } catch (e) {
      hilog.warn(0x0001, TAG, `showCommentDialog throw: ${JSON.stringify(e)}`);
    }
  }

  /** 关于 → 删除连接健康度日志: clears all persisted SLA timelines (2h 窗口
   * 与各相机 tracker), destructive so it asks for confirmation. */
  private onAboutClearSla(): void {
    this.getUIContext().getPromptAction().showDialog({
      title: '删除连接健康度日志',
      message: '将清除所有相机的「过去 2 小时连接健康度」记录，且无法恢复。确定删除？',
      buttons: [
        { text: '取消', color: $r('app.color.text_secondary') },
        { text: '删除', color: $r('app.color.danger') }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        cameraService.clearAllSla();
        // If the info sheet is open, it must not keep showing stale cells.
        this.slaCells = [];
        this.slaTooltip = '';
        this.slaTooltipIndex = -1;
        this.getUIContext().getPromptAction().showToast({ message: '已删除连接健康度日志', duration: 2000 });
      }
    }).catch((err: Error) => {
      hilog.warn(0x0001, TAG, 'Clear SLA dialog err: ' + err.message);
    });
  }
  private onAboutReset(): void {
    cameraService.resetOnboarding();
    this.getUIContext().getPromptAction().showToast({ message: '已重置引导提示，下次操作将重新显示', duration: 2500 });
  }

  build() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column() {
          Blank().height(56)

          if (cameraService.isPairingBonding()) { this.pairingNotice() }
          this.gpsCard()

          Text('连接开关打开的相机将保持连接，断开后自动重连。\n左滑设备卡片可删除配对；未配对的相机请先在「配对」页扫描添加。\n需要后台下发数据，请在系统设置中允许始终定位。')
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
    .bindSheet($$this.showSheet, this.sheetContent(), {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true,
      backgroundColor: $r('app.color.page_background'),
      enableOutsideInteractive: false // 半模态打开时禁止操作底下 UI
    })
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

@Component
struct InfoRow {
  @Prop label: string = '';
  @Prop value: string = '--';
  build() {
    Row() {
      Text(this.label).fontSize(14).fontColor($r('app.color.text_secondary')).width(80)
      Text(this.value).fontSize(14).fontColor($r('app.color.text_primary')).layoutWeight(1)
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').padding({ left: 16, right: 12, top: 10, bottom: 10 })
  }
}
