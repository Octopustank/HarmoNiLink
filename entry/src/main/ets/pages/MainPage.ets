/**
 * MainPage.ets — Tab container for HarmoNiLink
 *
 * Wraps HdsTabs in HdsNavigation (critical: HdsNavDestination requires
 * HdsNavigation context for correct title bar positioning).
 *
 * Structure mirrors the MultiDeviceCommunication sample:
 *   HdsNavigation → HdsTabs → TabContent(expandSafeArea) → HdsNavDestination → Scroll
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { cameraService } from '../service/CameraService';
import { PairingPage } from './PairingPage';
import { ConnectionPage } from './ConnectionPage';
import { HdsNavigation, HdsTabs, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-MainPage';

@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0;
  // Ready gate: tabs render only after the persisted index is known, so a
  // cold start never flashes the wrong tab (prefs.init is async).
  @State tabReady: boolean = false;
  // Plain field (NOT @Provide): HdsNavigation mutates this NavPathStack during
  // render, and @Provide would make ArkUI treat that as an illegal state change
  // ("changed during render") — no child @Consumes it, so plain is safe.
  private pathStack: NavPathStack = new NavPathStack();
  private tabsController: HdsTabsController = new HdsTabsController();

  aboutToAppear(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] MainPage aboutToAppear');
    const ctx = this.getUIContext().getHostContext();
    if (ctx) {
      cameraService.setContext(ctx as common.UIAbilityContext); // idempotent — prefs already init'd in onCreate
    }
    // Tab persistence: wait for prefs readiness (synchronous barrier, not a
    // deferred re-read) then render the last-visited tab directly.
    cameraService.whenPrefsReady().then(() => {
      const idx = cameraService.loadLastTabIndex();
      this.currentIndex = Math.min(Math.max(idx, 0), 1); // clamp 0/1
      this.tabReady = true;
    });
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
    if (!this.tabReady) {
      Column()
        .width('100%').height('100%')
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      HdsNavigation(this.pathStack) {
        HdsTabs({ barPosition: BarPosition.End, controller: this.tabsController, index: this.currentIndex }) {        TabContent() {
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
        .onChange((index: number) => {
          this.currentIndex = index;
          cameraService.saveLastTabIndex(index);
        })
        .width('100%')
        .height('100%')
        .backgroundColor($r('app.color.page_background'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
      .hideTitleBar(true)
      .hideToolBar(true)
      // Force stack mode: on wide windows (foldable expanded / tablet) HdsNavigation
      // defaults to split (parallel view), pinning the tabs to a narrow left column
      // with an empty right area. Stack makes the UI fill the whole window.
      .mode(NavigationMode.Stack)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }
}
