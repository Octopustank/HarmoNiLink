/**
 * MainPage.ets — Tab container for HarmoNiLink
 *
 * Wraps HdsTabs in HdsNavigation (critical: HdsNavDestination requires
 * HdsNavigation context for correct title bar positioning).
 *
 * Structure mirrors MultiDeviceCommunication Index.ets:
 *   HdsNavigation → HdsTabs → TabContent(expandSafeArea) → HdsNavDestination → Scroll
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { cameraService, ConnectionState } from '../service/CameraService';
import { PairingPage } from './PairingPage';
import { ConnectionPage } from './ConnectionPage';
import { HdsNavigation, HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-MainPage';

@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0;
  @Provide pathStack: NavPathStack = new NavPathStack();
  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] MainPage aboutToAppear');
    const ctx = getContext(this) as common.UIAbilityContext;
    cameraService.setContext(ctx);
    cameraService.setStateListener((state: ConnectionState) => { /* handled in tabs */ });
  }

  @Builder tabBar(index: number, label: string, icon: Resource) {
    Column() {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.currentIndex === index ? $r('app.color.brand') : $r('app.color.text_secondary')])
      Text(label)
        .fontSize(10)
        .fontColor(this.currentIndex === index ? $r('app.color.brand') : $r('app.color.text_secondary'))
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .margin({ top: 2 })
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .height('100%')
    .width('100%')
  }

  build() {
    HdsNavigation(this.pathStack) {
      HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.currentIndex }) {
        TabContent() {
          PairingPage()
        }
        .tabBar(this.tabBar(0, '配对', $r('sys.symbol.camera')))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

        TabContent() {
          ConnectionPage()
        }
        .tabBar(this.tabBar(1, '连接', $r('sys.symbol.person')))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .barHeight(56)
      .barOverlap(true)
      .scrollable(false)
      .barFloatingStyle({
        barBottomMargin: 0,
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.IMMERSIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      })
      .onChange((index: number) => { this.currentIndex = index; })
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
    .hideTitleBar(true)
    .hideToolBar(true)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .systemBarStyle(
      { statusBarContentColor: '#1A1A1A' },
      { statusBarContentColor: '#FFFFFF' }
    )
  }
}
