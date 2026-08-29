/**
 * PairingPage.ets — Device discovery & pairing tab
 *
 * MessagesCommonView pattern (HdsNavDestination < HdsNavigation required).
 * WlanSection card pattern for device list.
 *
 * Ownership: uses cameraService.requestOwnership('pairing') so ConnectionPage
 * operations are blocked while pairing is active, and vice versa.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { cameraService } from '../service/CameraService';
import { ConnectionState, CameraStateEvent } from '../service/ConnectionTypes';
import { DiscoveredCamera } from '../ble/BleScanner';
import { HdsNavDestination, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-PairingPage';

@Component
export struct PairingPage {
  @State discoveredCameras: DiscoveredCamera[] = [];
  @State showOthers: boolean = false; // "其他设备" collapsed section
  @State pairingTarget: string = ''; // deviceName — event routing + status
  @State pairingTargetId: string = ''; // deviceId — per-row spinner (virtual-MAC dedupe)
  @State statusLabel: string = '';
  @State owner: string = 'none'; // synced from cameraService — drives @State re-render
  @State state: ConnectionState = ConnectionState.Idle; // reactive mirror for button states
  @State scanToggleOn: boolean = false; // 蓝牙扫描开关 — reflects Scanning state
  // Bumped to force the ForEach to re-render its rows: isPaired() is a LIVE
  // prefs read, so a plain array reassign won't refresh it (ForEach reuses
  // items whose key is unchanged). Bump after pairing completes / on tab focus.
  @State listRefreshTick: number = 0;
  private scroller: Scroller = new Scroller();
  private scanTimer: number = -1;
  private offStateListener: (() => void) | null = null;
  private offDevicesChanged: (() => void) | null = null;

  // Derived helpers
  private isPairingTabOwner(): boolean { return this.owner === 'pairing'; }
  private isConnectionTabBusy(): boolean { return this.owner === 'connection'; }

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] PairingPage aboutToAppear');
    // Re-enter (tab focus): re-sync owner + scan-toggle + list from the service
    // (the component instance may have been recreated, so @State mirrors reset).
    this.owner = cameraService.getOwner();
    this.scanToggleOn = cameraService.isPairScanning();
    this.discoveredCameras = cameraService.getDiscoveredCameras();
    this.listRefreshTick++;
    // A scan/pairing may still be in flight while this tab was hidden — resume
    // polling (aboutToDisappear stopped it) so the list keeps updating.
    if (cameraService.getOwner() === 'pairing') {
      this.startPolling();
    }
    // Re-render 已配对 markers whenever the paired-device set changes — a
    // camera removed from the Connection page must stop showing 已配对 here,
    // even while this tab is hidden.
    this.offDevicesChanged = cameraService.onDevicesChanged(() => {
      this.listRefreshTick++;
    });
    this.offStateListener = cameraService.setStateListener((event: CameraStateEvent) => {
      this.owner = cameraService.getOwner();
      // Only react to global events (pairing scan / ownership) and this page's
      // pairing target — ignore other cameras' connection events.
      const relevant = event.cameraName === ''
        || (this.pairingTarget !== '' && event.cameraName === this.pairingTarget);
      if (!relevant) return;
      const s = event.state;
      this.state = s;
      // Scan toggle mirrors Scanning (pairing hands off to GATT, not scan).
      this.scanToggleOn = this.isPairingTabOwner() && s === ConnectionState.Scanning;
      if (this.isPairingTabOwner()) {
        // Our operation — show detailed progress in the title-bar subtitle
        if (s === ConnectionState.Scanning) {
          this.statusLabel = '正在搜索附近的相机…';
        } else if (s === ConnectionState.Connecting) {
          this.statusLabel = `正在连接 ${this.pairingTarget}…`;
        } else if (s === ConnectionState.Discovering) {
          this.statusLabel = '正在发现服务…';
        } else if (s === ConnectionState.Pairing) {
          this.statusLabel = `正在进行配对 (${Math.min(cameraService.getPairingStepFor(this.pairingTarget), 4)}/4)…`;
        } else if (s === ConnectionState.Bonding) {
          this.statusLabel = '正在经典蓝牙绑定…';
        } else if (s === ConnectionState.Idle) {
          this.stopPolling();
          if (this.pairingTarget && cameraService.getPairingStepFor(this.pairingTarget) === 6) {
            // Genuine pairing completion (handshake finished) — success dialog.
            const target = this.pairingTarget;
            this.pairingTarget = ''; this.pairingTargetId = '';
            this.listRefreshTick++;
            this.getUIContext().getPromptAction().showDialog({
              title: '配对成功',
              message: `「${target}」已添加到已配对设备列表。\n请前往「连接」页面手动连接相机。`,
              buttons: [{ text: '好的', color: $r('app.color.brand') }]
            }).catch(() => { /* dialog dismissed */ });
          } else if (this.pairingTarget !== '') {
            // Pairing failed (target set but handshake/bond didn't reach 6) —
            // mirror the success dialog with the concrete failure reason.
            const reason = event.message;
            this.pairingTarget = ''; this.pairingTargetId = '';
            this.listRefreshTick++;
            this.getUIContext().getPromptAction().showDialog({
              title: '配对失败',
              message: reason !== '' ? reason : '连接已断开，请重新连接',
              buttons: [{ text: '知道了', color: $r('app.color.brand') }]
            }).catch(() => { /* dialog dismissed */ });
          }
          // Idle: clear the title-bar status (success/failure/cancel) — don't
          // show a standing "准备就绪" (the Connection page shows none either).
          this.statusLabel = '';
        } else if (s === ConnectionState.Error) {
          this.statusLabel = '配对出错，请重试'; this.pairingTarget = ''; this.pairingTargetId = '';
          this.stopPolling();
        }
      } else if (this.isConnectionTabBusy()) {
        this.statusLabel = '连接页操作中'; this.stopPolling();
        this.pairingTarget = ''; this.pairingTargetId = '';
      } else {
        this.statusLabel = s === ConnectionState.Error ? '配对出错，请重试' : '';
        this.pairingTarget = ''; this.pairingTargetId = ''; // safety net — never leave a stale target locked
        this.stopPolling();
      }
    });
  }

  aboutToDisappear(): void {
    this.stopPolling();
    if (this.offStateListener) { this.offStateListener(); this.offStateListener = null; }
    if (this.offDevicesChanged) { this.offDevicesChanged(); this.offDevicesChanged = null; }
  }

  private nikonCameras(): DiscoveredCamera[] {
    return this.discoveredCameras.filter((c: DiscoveredCamera) => c.isNikon);
  }
  private otherCameras(): DiscoveredCamera[] {
    return this.discoveredCameras.filter((c: DiscoveredCamera) => !c.isNikon);
  }

  private isPaired(cam: DiscoveredCamera): boolean {
    return cameraService.isPairedCamera(cam.deviceName);
  }

  @Builder cameraRow(cam: DiscoveredCamera) {
    Row() {
      Column() {
        Row({ space: 6 }) {
          Text(cam.deviceName)
            .fontSize(16).fontWeight(500)
            .fontColor(this.isPaired(cam) ? $r('app.color.link') : $r('app.color.text_primary'))
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.isPaired(cam)) {
            Text('已配对').fontSize(12).fontColor($r('app.color.text_secondary'))
          }
        }
        Text(`RSSI: ${cam.rssi}`).fontSize(14).fontColor($r('app.color.text_secondary')).margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)

      // 配对中 — 加载动画，点击行取消 (match by deviceId: virtual-MAC
      // duplicates share a name but differ by address, so only the tapped row
      // should spin)
      if (this.pairingTargetId === cam.deviceId) {
        LoadingProgress()
          .width(22).height(22)
          .color($r('app.color.brand'))
      }

      // info 按钮 — 独立点击区查看设备详情
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(22)
        .fontColor([$r('app.color.text_secondary')])
        .margin({ left: 12 })
        .padding(4)
        .onClick(() => { this.onInfo(cam); })
    }
    .width('100%').height(48).padding({ left: 8, right: 8 })
    .margin({ top: 4, bottom: 4 })
    .borderRadius(16)
    .stateStyles({
      pressed: { .backgroundColor($r('app.color.press_feedback')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick(() => { this.onCameraRowTap(cam); })
  }

  private onCameraRowTap(cam: DiscoveredCamera): void {
    if (this.isPaired(cam)) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '该设备已配对，请在「连接」页管理', duration: 2000 });
      } catch (e) {
        hilog.warn(0x0001, TAG, `paired toast err: ${(e as Error).message}`);
      }
      return;
    }
    if (this.pairingTargetId === cam.deviceId) {
      this.cancelCurrentPairing(); // 再点取消配对
      return;
    }
    if (this.pairingTarget !== '') return; // 另一台设备配对中
    this.onPair(cam);
  }

  private onInfo(cam: DiscoveredCamera): void {
    const lines: string[] = [
      `名称：${cam.deviceName}`,
      `地址：${cam.deviceId}`,
      `信号：${cam.rssi} dBm`,
      `类型：${cam.isNikon ? '尼康相机' : '其他设备'}`,
      `可连接：${cam.isConnectable ? '是' : '否'}`,
    ];
    if (cam.manufacturerDevice !== undefined) {
      lines.push(`设备 ID：0x${(cam.manufacturerDevice >>> 0).toString(16).toUpperCase()}`);
    }
    this.getUIContext().getPromptAction().showDialog({
      title: cam.deviceName,
      message: lines.join('\n'),
      buttons: [{ text: '关闭', color: $r('app.color.brand') }]
    }).catch(() => { /* dialog dismissed */ });
  }

  private startPolling(): void {
    this.stopPolling();
    this.scanTimer = setInterval(() => {
      const latest = cameraService.getDiscoveredCameras();
      // Skip re-render if the list hasn't changed (deviceId + rssi stable keys)
      if (this.isSameList(latest)) return;
      this.discoveredCameras = latest;
    }, 500);
  }

  private stopPolling(): void {
    if (this.scanTimer !== -1) { clearInterval(this.scanTimer); this.scanTimer = -1; }
  }

  private isSameList(latest: DiscoveredCamera[]): boolean {
    const prev = this.discoveredCameras;
    if (latest.length !== prev.length) return false;
    for (let i = 0; i < latest.length; i++) {
      if (latest[i].deviceId !== prev[i].deviceId || latest[i].rssi !== prev[i].rssi) return false;
    }
    return true;
  }

  private cancelCurrentPairing(): void {
    this.pairingTarget = ''; this.pairingTargetId = '';
    cameraService.cancelPairing();
    this.statusLabel = ''; // idle — no standing status
  }

  onScanToggle(on: boolean): void {
    if (on) {
      // User is switching the 蓝牙扫描 toggle ON.
      if (this.owner !== 'none') {
        this.scanToggleOn = false; // snap back — radio is busy elsewhere
        try { this.getUIContext().getPromptAction().showToast({ message: '正在操作中，请稍后', duration: 2000 }); } catch (e) {}
        return;
      }
      // Request permissions on first user action (system queues dialogs;
      // avoids the startup privacy-dialog conflict). Scan only when granted.
      cameraService.requestPermissionsIfNeeded().then((granted: boolean) => {
        if (!granted) {
          this.scanToggleOn = false;
          this.getUIContext().getPromptAction().showToast({ message: '需要蓝牙和位置权限才能扫描', duration: 2500 });
          return;
        }
        // One-time prompt (persistent flag + live state, NOT the "just granted"
        // event): explain precise location, and that background GPS requires
        // "always allow" in system settings (optional). Latches the flag the
        // moment it pops (either button = shown), so a reset (关于 → 重置引导)
        // is the only way to replay it — re-scanning alone never re-asks.
        if (!cameraService.wasPermissionHintShown() && !cameraService.isBackgroundLocationGranted()) {
          cameraService.markPermissionHintShown();
          this.getUIContext().getPromptAction().showDialog({
            title: '定位权限说明',
            message: '已授予位置权限。\n\n请确保授予「精确位置」，相机才能收到准确的 GPS 坐标。\n\n如需相机休眠或应用在后台时持续下发 GPS，请在系统设置中将定位权限设为「始终允许」（会略微增加耗电）。',
            buttons: [
              { text: '暂不', color: $r('app.color.text_secondary') },
              { text: '去开启', color: $r('app.color.brand') }
            ]
          }).then((result: promptAction.ShowDialogSuccessResponse) => {
            if (result.index === 1) {
              cameraService.openBackgroundLocationSetting();
            }
          }).catch(() => { /* dialog dismissed */ });
        }
        if (cameraService.startPairingScan()) {
          this.startPolling();
        } else {
          this.scanToggleOn = false;
          this.getUIContext().getPromptAction().showToast({ message: '连接页操作中，请稍后', duration: 2000 });
        }
      });
    } else {
      // User is switching the toggle OFF — stop scanning if scanning.
      if (this.isPairingTabOwner() && this.state === ConnectionState.Scanning) {
        this.pairingTarget = ''; this.pairingTargetId = '';
        cameraService.stopPairingScan();
        this.statusLabel = '扫描已停止';
      }
    }
  }

  onPair(cam: DiscoveredCamera): void {
    // Allow pairing when idle (owner none) — acquire ownership on demand.
    // Still blocked while the connection tab owns the resource.
    if (this.owner !== 'none' && !this.isPairingTabOwner()) return;
    if (this.owner === 'none') {
      if (!cameraService.requestOwnership('pairing')) {
        try { this.getUIContext().getPromptAction().showToast({ message: '连接页操作中，请稍后', duration: 2000 }); } catch (e) {}
        return;
      }
    }
    hilog.info(0x0001, TAG, `[CHECKPOINT] Pairing with ${cam.deviceName}`);
    this.pairingTarget = cam.deviceName;
    this.pairingTargetId = cam.deviceId; // tap THIS address, not its name-twin
    this.stopPolling();
    this.statusLabel = `正在与 ${cam.deviceName} 配对…`;
    cameraService.selectDiscoveredCamera(cam);
  }

  build() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column() {
          Blank().height(56)

          // 蓝牙扫描开关 — settings-style toggle card (参考 WLAN 顶部)
          Row() {
            Column() {
              Text('蓝牙扫描').fontSize(16).fontWeight(500).fontColor($r('app.color.text_primary'))
              Text('扫描附近的相机设备').fontSize(14).fontColor($r('app.color.text_secondary')).margin({ top: 2 })
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.scanToggleOn })
              // Disabled while pairing is in flight (busy) or the Connection
              // tab owns the radio — a dead-looking switch is clearer than a
              // flippable one that just toasts "请稍后".
              .enabled(this.owner === 'none'
                || (this.isPairingTabOwner() && this.state === ConnectionState.Scanning))
              .onChange((on: boolean) => { this.onScanToggle(on); })
          }
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(16).backgroundColor($r('app.color.card_background'))
          .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
          .margin({ top: 12, bottom: 6 })

          Text('将相机置于配对模式，确保蓝牙已开启')
            .fontSize(11).fontColor($r('app.color.text_secondary'))
            .width('100%').textAlign(TextAlign.Start)
            .margin({ left: 16, bottom: 8 })

          if (this.discoveredCameras.length > 0) {
            Text('已发现的设备').fontSize(14).fontColor($r('app.color.text_secondary'))
              .margin({ left: 12, bottom: 8, top: 28 }).alignSelf(ItemAlign.Start).fontWeight(500)

            // 尼康相机置顶（UUID 0xDE00 或命名匹配）— 标题始终显示（含 0）
            Text(`尼康相机（${this.nikonCameras().length}）`).fontSize(13).fontColor($r('app.color.text_secondary'))
              .margin({ left: 12, bottom: 6, top: 8 }).alignSelf(ItemAlign.Start)
            if (this.nikonCameras().length > 0) {
              Column() {
                ForEach(this.nikonCameras(), (cam: DiscoveredCamera, index: number) => {
                  this.cameraRow(cam)
                  if (index < this.nikonCameras().length - 1) {
                    Divider().strokeWidth(0.5).color($r('app.color.divider'))
                      .margin({ left: 8, right: 8 })
                  }
                },
                  (cam: DiscoveredCamera) => `${cam.deviceId}_${this.listRefreshTick}`)
              }
              .width('100%').backgroundColor($r('app.color.card_background')).borderRadius(16).padding(4)
              .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
            }

            // 其他设备（默认折叠）— 纯展开/收起控制，无按压高亮（点击即切换，
            // 瞬时高亮无意义还会闪）
            Row() {
              Text(`其他设备（${this.otherCameras().length}）`).fontSize(13).fontColor($r('app.color.text_secondary'))
              Blank()
              Text(this.showOthers ? '收起' : '展开').fontSize(13).fontColor($r('app.color.brand'))
            }
            .width('100%').padding({ left: 12, right: 12, top: 12, bottom: 4 })
            .onClick(() => { this.showOthers = !this.showOthers; })
            if (this.showOthers) {
              Column() {
                ForEach(this.otherCameras(), (cam: DiscoveredCamera, index: number) => {
                  this.cameraRow(cam)
                  if (index < this.otherCameras().length - 1) {
                    Divider().strokeWidth(0.5).color($r('app.color.divider'))
                      .margin({ left: 8, right: 8 })
                  }
                },
                  (cam: DiscoveredCamera) => `${cam.deviceId}_${this.listRefreshTick}`)
              }
              .width('100%').backgroundColor($r('app.color.card_background')).borderRadius(16).padding(4)
              .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
            }
          } else {
            Column() {
              Text(this.pairingTarget !== ''
                ? `正在与 ${this.pairingTarget} 配对…`
                : this.isPairingTabOwner() ? '正在搜索附近的相机...' : '开启蓝牙扫描搜索设备')
                .fontSize(13).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          }

          Blank().layoutWeight(1)
        }
        .padding({ left: 16, right: 16, bottom: 56 })
      }
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .backgroundColor($r('app.color.page_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .titleBar({
      content: { title: { mainTitle: '配对', subTitle: this.statusLabel || undefined } },
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
