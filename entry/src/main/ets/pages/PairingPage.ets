/**
 * PairingPage.ets — Device discovery & pairing tab
 *
 * MessagesCommonView pattern (HdsNavDestination < HdsNavigation required).
 * WlanSection card pattern for device list.
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
  @State isScanning: boolean = false;
  @State isPairing: boolean = false;
  @State pairingTarget: string = '';
  @State titleSub: string = '';
  @State statusLabel: string = '准备就绪';
  private scroller: Scroller = new Scroller();
  private scanTimer: number = -1;

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] PairingPage aboutToAppear');
    cameraService.setStateListener((s: ConnectionState) => {
      const isBusy = s !== ConnectionState.Idle
        && s !== ConnectionState.Ready
        && s !== ConnectionState.Error;
      // Track scanning — only if WE started it
      if (s === ConnectionState.Scanning) {
        if (this.isScanning) { this.titleSub = '正在扫描设备…'; }
      } else if (this.isScanning && s !== ConnectionState.Connecting
        && s !== ConnectionState.Discovering && s !== ConnectionState.Pairing
        && s !== ConnectionState.Bonding) {
        this.isScanning = false; this.stopPolling(); this.titleSub = '';
      }
      // Track pairing — only if WE started it
      if (s === ConnectionState.Connecting && this.isPairing) {
        this.statusLabel = `正在与 ${this.pairingTarget} 配对…`;
      } else if (this.isScanning) {
        this.statusLabel = '正在搜索附近的相机…';
      } else if (isBusy && !this.isPairing && !this.isScanning) {
        // External operation in progress (e.g. reconnect from ConnectionPage)
        this.statusLabel = '连接页操作中，等待完成…';
      } else if (!isBusy) {
        this.statusLabel = this.pairingTarget ? '' : '准备就绪';
      }
      // Pairing completed successfully (our operation)
      if (!isBusy && this.isPairing && s === ConnectionState.Ready) {
        this.isPairing = false; this.pairingTarget = ''; this.statusLabel = '';
        this.isScanning = false; this.stopPolling(); this.titleSub = '';
        cameraService.disconnect();
        promptAction.showDialog({
          title: '配对成功',
          message: '已添加到已配对设备列表。\n断开连接后，请前往「连接」页面手动连接相机。',
          buttons: [{ text: '好的', color: $r('app.color.brand') }]
        });
      } else if (!isBusy && this.isPairing) {
        this.isPairing = false; this.pairingTarget = ''; this.statusLabel = '配对失败，请重试';
      }
    });
  }

  aboutToDisappear(): void { this.stopPolling(); }

  startPolling(): void {
    this.stopPolling();
    this.scanTimer = setInterval(() => { this.discoveredCameras = cameraService.getDiscoveredCameras(); }, 500);
  }

  stopPolling(): void {
    if (this.scanTimer !== -1) { clearInterval(this.scanTimer); this.scanTimer = -1; }
  }

  onScan(): void {
    hilog.info(0x0001, TAG, `[CHECKPOINT] onScan isScanning=${this.isScanning}`);
    if (this.isScanning) { cameraService.stopScan(); this.isScanning = false; this.stopPolling(); this.statusLabel = '扫描已停止'; }
    else { cameraService.startScan(); this.isScanning = true; this.startPolling(); this.statusLabel = '正在搜索附近的相机…'; }
  }

  private isExternalBusy(): boolean {
    const s = cameraService.getState();
    return (s === ConnectionState.Scanning || s === ConnectionState.Connecting
      || s === ConnectionState.Discovering || s === ConnectionState.Pairing
      || s === ConnectionState.Bonding) && !this.isScanning && !this.isPairing;
  }

  onPair(cam: DiscoveredCamera): void {
    if (this.isPairing) return;
    hilog.info(0x0001, TAG, `[CHECKPOINT] Pairing with ${cam.deviceName}`);
    this.isPairing = true;
    this.pairingTarget = cam.deviceName;
    this.isScanning = false; this.stopPolling();
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
              .fill(this.isScanning || this.isPairing ? $r('app.color.warning')
                : this.isExternalBusy() ? $r('app.color.warning') : $r('app.color.text_secondary'))
            Text(this.isExternalBusy() ? '连接页操作中' : this.statusLabel)
              .fontSize(13).fontColor($r('app.color.text_secondary')).margin({ left: 8 })
          }
          .width('100%').padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .borderRadius(16).backgroundColor($r('app.color.card_background'))
          .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })

          Button(this.isScanning ? '停止扫描' : '开始扫描')
            .fontSize(15).fontWeight(FontWeight.Medium).height(44).borderRadius(22)
            .backgroundColor(this.isScanning ? $r('app.color.danger') : $r('app.color.brand')).fontColor(Color.White)
            .padding({ left: 48, right: 48 })
            .margin({ top: 12, bottom: 16 })
            .enabled(!this.isPairing && !this.isExternalBusy())
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
                  if (this.isPairing && this.pairingTarget === cam.deviceName) {
                    Button('配对中…')
                      .fontSize(13).fontWeight(FontWeight.Medium)
                      .height(32).borderRadius(16).backgroundColor('#FF9500').fontColor(Color.White)
                      .padding({ left: 16, right: 16 })
                  } else if (this.isPairing) {
                    Button('配对')
                      .fontSize(13).fontWeight(FontWeight.Medium)
                      .height(32).borderRadius(16).backgroundColor($r('app.color.disabled_bg')).fontColor($r('app.color.card_background'))
                      .padding({ left: 16, right: 16 }).enabled(false)
                  } else {
                    Button('配对').fontSize(13).fontWeight(FontWeight.Medium)
                      .height(32).borderRadius(16).backgroundColor($r('app.color.brand')).fontColor(Color.White)
                      .padding({ left: 16, right: 16 }).onClick(() => { this.onPair(cam); })
                  }
                }.width('100%').height(48).padding({ left: 8, right: 8 })
                if (i < this.discoveredCameras.length - 1) {
                  Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 8, right: 8 })
                }
              }, (cam: DiscoveredCamera, i: number) => cam.deviceId + i)
            }
            .width('100%').backgroundColor($r('app.color.card_background')).borderRadius(16).padding(4)
            .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
          } else {
            Column() {
              Text(this.isPairing
                ? `正在与 ${this.pairingTarget} 配对…`
                : this.isScanning ? '正在搜索附近的相机...' : '点击「开始扫描」搜索设备')
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
