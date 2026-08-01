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
import { cameraService, ConnectionState } from '../service/CameraService';
import { DiscoveredCamera } from '../ble/BleScanner';
import { HdsNavDestination, ScrollEffectType, hdsMaterial } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-PairingPage';

@Component
export struct PairingPage {
  @State discoveredCameras: DiscoveredCamera[] = [];
  @State pairingTarget: string = '';
  @State titleSub: string = '';
  @State statusLabel: string = '准备就绪';
  @State owner: string = 'none'; // synced from cameraService — drives @State re-render
  @State state: ConnectionState = ConnectionState.Idle; // reactive mirror for button states
  private scroller: Scroller = new Scroller();
  private scanTimer: number = -1;

  // Derived helpers
  private isPairingTabOwner(): boolean { return this.owner === 'pairing'; }
  private isConnectionTabBusy(): boolean { return this.owner === 'connection'; }
  private isPairingBusy(): boolean {
    return this.state === ConnectionState.Connecting || this.state === ConnectionState.Discovering
      || this.state === ConnectionState.Pairing || this.state === ConnectionState.Bonding;
  }
  private scanButtonLabel(): string {
    if (this.isPairingTabOwner() && this.state === ConnectionState.Scanning) return '停止扫描';
    if (this.isPairingTabOwner() && this.isPairingBusy()) return '取消配对';
    return '开始扫描';
  }
  private scanButtonColor(): ResourceColor {
    if (this.isPairingTabOwner() && this.state === ConnectionState.Scanning) return $r('app.color.danger');
    if (this.isPairingTabOwner() && this.isPairingBusy()) return $r('app.color.danger');
    return $r('app.color.brand');
  }

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] PairingPage aboutToAppear');
    cameraService.setStateListener((s: ConnectionState) => {
      this.owner = cameraService.getOwner();
      this.state = s;
      if (this.isPairingTabOwner()) {
        // Our operation — show detailed progress
        if (s === ConnectionState.Scanning) {
          this.titleSub = '正在扫描设备…'; this.statusLabel = '正在搜索附近的相机…';
        } else if (s === ConnectionState.Connecting) {
          this.titleSub = ''; this.statusLabel = `正在连接 ${this.pairingTarget}…`;
        } else if (s === ConnectionState.Discovering) {
          this.titleSub = ''; this.statusLabel = '正在发现服务…';
        } else if (s === ConnectionState.Pairing) {
          this.titleSub = ''; this.statusLabel = '正在进行安全握手…';
        } else if (s === ConnectionState.Bonding) {
          this.titleSub = ''; this.statusLabel = '正在经典蓝牙绑定…';
        } else if (s === ConnectionState.Idle) {
          this.titleSub = ''; this.stopPolling();
          if (this.pairingTarget && cameraService.getPairingStep() === 6) {
            // Genuine pairing completion (handshake finished) — show success
            const target = this.pairingTarget;
            this.pairingTarget = '';
            this.statusLabel = '配对完成';
            promptAction.showDialog({
              title: '配对成功',
              message: `「${target}」已添加到已配对设备列表。\n请前往「连接」页面手动连接相机。`,
              buttons: [{ text: '好的', color: $r('app.color.brand') }]
            });
          } else {
            // Cancel / failure / connection drop — clear the stuck target state
            this.pairingTarget = '';
            this.statusLabel = '准备就绪';
          }
        } else if (s === ConnectionState.Error) {
          this.titleSub = ''; this.statusLabel = '配对出错，请重试'; this.pairingTarget = '';
          this.stopPolling();
        }
      } else if (this.isConnectionTabBusy()) {
        this.titleSub = ''; this.statusLabel = '连接页操作中'; this.stopPolling();
        this.pairingTarget = '';
      } else {
        this.titleSub = '';
        this.statusLabel = s === ConnectionState.Error ? '配对出错，请重试' : '准备就绪';
        this.pairingTarget = ''; // safety net — never leave a stale target locked
        this.stopPolling();
      }
    });
  }

  aboutToDisappear(): void { this.stopPolling(); }

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
    this.pairingTarget = '';
    cameraService.cancelPairing();
    this.statusLabel = '已取消';
  }

  onScan(): void {
    if (this.isPairingTabOwner() && this.state === ConnectionState.Scanning) {
      // Stop scanning — clear any stale pairing target first so the device list
      // never stays locked on "配对中…"
      this.pairingTarget = '';
      cameraService.stopPairingScan();
      this.statusLabel = '扫描已停止';
    } else if (this.isPairingTabOwner() && this.isPairingBusy()) {
      // Active pairing/connecting — user-initiated cancel
      this.cancelCurrentPairing();
    } else if (this.owner === 'none') {
      // Request permissions on first user action (system queues dialogs;
      // avoids the startup privacy-dialog conflict). Scan only when granted.
      cameraService.requestPermissionsIfNeeded().then((granted: boolean) => {
        if (!granted) {
          promptAction.showToast({ message: '需要蓝牙和位置权限才能扫描', duration: 2500 });
          return;
        }
        // One-time prompt after first grant: explain precise location, and that
        // background GPS requires "always allow" in system settings (optional).
        if (cameraService.wasPermissionJustGranted() && !cameraService.isBackgroundLocationGranted()) {
          promptAction.showDialog({
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
          promptAction.showToast({ message: '连接页操作中，请稍后', duration: 2000 });
        }
      });
    } else {
      promptAction.showToast({ message: '正在操作中，请稍后', duration: 2000 });
    }
  }

  onPair(cam: DiscoveredCamera): void {
    // Allow pairing when idle (owner none) — acquire ownership on demand.
    // Still blocked while the connection tab owns the resource.
    if (this.owner !== 'none' && !this.isPairingTabOwner()) return;
    if (this.owner === 'none') {
      if (!cameraService.requestOwnership('pairing')) {
        promptAction.showToast({ message: '连接页操作中，请稍后', duration: 2000 });
        return;
      }
    }
    hilog.info(0x0001, TAG, `[CHECKPOINT] Pairing with ${cam.deviceName}`);
    this.pairingTarget = cam.deviceName;
    this.stopPolling();
    this.statusLabel = `正在与 ${cam.deviceName} 配对…`;
    cameraService.selectDiscoveredCamera(cam);
  }

  build() {
    HdsNavDestination() {
      Scroll(this.scroller) {
        Column() {
          Blank().height(56)

          // Status card
          Row() {
            Circle({ width: 8, height: 8 })
              .fill(this.isPairingTabOwner() ? $r('app.color.warning')
                : this.isConnectionTabBusy() ? $r('app.color.warning') : $r('app.color.text_secondary'))
            Text(this.statusLabel)
              .fontSize(13).fontColor($r('app.color.text_secondary')).margin({ left: 8 })
          }
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(16).backgroundColor($r('app.color.card_background'))
          .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })

          Button(this.scanButtonLabel())
            .fontSize(15).fontWeight(FontWeight.Medium).height(44).borderRadius(22)
            .backgroundColor(this.scanButtonColor()).fontColor(Color.White)
            .padding({ left: 48, right: 48 })
            .margin({ top: 12, bottom: 16 })
            .enabled(this.owner === 'none' || this.isPairingTabOwner())
            .onClick(() => { this.onScan(); })

          if (this.discoveredCameras.length > 0) {
            Text('已发现的设备').fontSize(14).fontColor($r('app.color.text_secondary'))
              .margin({ left: 12, bottom: 8, top: 28 }).alignSelf(ItemAlign.Start).fontWeight(500)

            Column() {
              ForEach(this.discoveredCameras, (cam: DiscoveredCamera, i: number) => {
                Row() {
                  Column() {
                    Text(cam.deviceName).fontSize(16).fontWeight(500).fontColor($r('app.color.text_primary'))
                      .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(`RSSI: ${cam.rssi}`).fontSize(14).fontColor($r('app.color.text_secondary')).margin({ top: 2 })
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  if (this.pairingTarget === cam.deviceName) {
                    Button('配对中…')
                      .fontSize(13).fontWeight(FontWeight.Medium)
                      .height(32).borderRadius(16).backgroundColor('#FF9500').fontColor(Color.White)
                      .padding({ left: 16, right: 16 })
                      .onClick(() => { this.cancelCurrentPairing(); })
                  } else if (this.pairingTarget !== '') {
                    Button('配对')
                      .fontSize(13).fontWeight(FontWeight.Medium)
                      .height(32).borderRadius(16).backgroundColor($r('app.color.disabled_bg')).fontColor($r('app.color.card_background'))
                      .padding({ left: 16, right: 16 }).enabled(false)
                  } else {
                    Button('配对').fontSize(13).fontWeight(FontWeight.Medium)
                      .height(32).borderRadius(16).backgroundColor($r('app.color.brand')).fontColor(Color.White)
                      .padding({ left: 16, right: 16 })
                      .enabled((this.owner === 'none' || this.isPairingTabOwner()) && this.pairingTarget === '')
                      .onClick(() => { this.onPair(cam); })
                  }
                }.width('100%').height(48).padding({ left: 8, right: 8 })
                if (i < this.discoveredCameras.length - 1) {
                  Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 8, right: 8 })
                }
              }, (cam: DiscoveredCamera) => cam.deviceId)
            }
            .width('100%').backgroundColor($r('app.color.card_background')).borderRadius(16).padding(4)
            .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
          } else {
            Column() {
              Text(this.pairingTarget !== ''
                ? `正在与 ${this.pairingTarget} 配对…`
                : this.isPairingTabOwner() ? '正在搜索附近的相机...' : '点击「开始扫描」搜索设备')
                .fontSize(13).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center)
            }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
          }

          Text('将相机置于配对模式，确保蓝牙已开启')
            .fontSize(11).fontColor($r('app.color.text_secondary')).textAlign(TextAlign.Center).width('100%')
            .padding({ top: 20 })

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
      content: { title: { mainTitle: '配对', subTitle: this.titleSub || undefined } },
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
