/**
 * MainPage.ets — Tab container for HarmoNiLink
 *
 * Wraps HdsTabs in HdsNavigation (critical: HdsNavDestination requires
 * HdsNavigation context for correct title bar positioning).
 *
 * Structure mirrors the MultiDeviceCommunication sample:
 *   HdsNavigation → HdsTabs → TabContent(expandSafeArea) → HdsNavDestination → Scroll
 *
 * Floating-window (小窗) mode lifts the floating tab bar off the window's
 * bottom edge (the system's navigation-bar avoidance doesn't apply inside a
 * free window). The inset rides windowStatusChange → re-render trigger →
 * METHOD-CALL param: per the 2026-08-29 on-device experiments (AGENTS.md),
 * params bound as a direct state reference froze into cross-file components
 * (HdsTabs is one), while method-call expressions are re-evaluated on every
 * parent re-render and survived.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { cameraService } from '../service/CameraService';
import { PairingPage } from './PairingPage';
import { ConnectionPage } from './ConnectionPage';
import { HdsNavigation, HdsTabs, HdsTabsController, hdsMaterial, HdsTabsAttribute, HdsTabsModifier } from '@kit.UIDesignKit';

const TAG = 'HarmoNiLink-MainPage';

// FLOATING (free window) bottom inset for the floating tab bar. 16vp matches
// the HDS floating bar's default side margin (barSideMargin 16vp) so the bar
// reads as one consistent inset language inside a small window. The official
// sample's 28vp is a full-screen-scene value — too large inside a free window.
// Confirmed on-device (16vp reads clean in a free window).
const TAB_BAR_BOTTOM_MARGIN_FLOATING: number = 16;
// FULL_SCREEN / SPLIT / PIP: rely on the system's navigation-bar avoidance —
// any margin here would double up with it.
const TAB_BAR_BOTTOM_MARGIN_DEFAULT: number = 0;

/**
 * Applies the floating style (incl. the mode-dependent bottom margin) through
 * the attributeModifier pipeline: applyNormalAttribute is re-invoked by the
 * framework whenever a NEW modifier instance is assigned — a runtime path in
 * the framework itself, not the compiler-generated cross-component param
 * binding that froze on-device (2026-08-29 experiments, AGENTS.md). A direct
 * .barFloatingStyle({...}) in build() was measured to be initialize-only:
 * HDS ignores later re-evaluations of that call.
 */
class FloatingTabsModifier extends HdsTabsModifier {
  private barMargin: number = TAB_BAR_BOTTOM_MARGIN_DEFAULT;

  setBarMargin(barMargin: number): FloatingTabsModifier {
    this.barMargin = barMargin;
    return this;
  }

  applyNormalAttribute(instance: HdsTabsAttribute): void {
    instance.barFloatingStyle({
      barBottomMargin: this.barMargin,
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    });
  }
}

@Entry
@Component
struct MainPage {
  @State currentIndex: number = 0;
  // Ready gate: tabs render only after the persisted index is known, so a
  // cold start never flashes the wrong tab (prefs.init is async).
  @State tabReady: boolean = false;
  // Re-render TRIGGER + runtime style carrier. Each windowStatusChange builds
  // a NEW modifier instance (assignment to a @State reference is the strongest
  // update signal) carrying the margin for the current mode.
  @State tabsModifier: FloatingTabsModifier = new FloatingTabsModifier()
    .setBarMargin(TAB_BAR_BOTTOM_MARGIN_DEFAULT);
  // Margin currently applied via the modifier — same-value events are skipped.
  private lastAppliedMargin: number = TAB_BAR_BOTTOM_MARGIN_DEFAULT;
  // Window handle + mode listener — kept to unregister on disappear.
  private mainWindow: window.Window | null = null;
  private windowStatusCb: ((status: window.WindowStatusType) => void) | null = null;
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
    this.watchWindowMode();
  }

  aboutToDisappear(): void {
    if (this.mainWindow && this.windowStatusCb) {
      try { this.mainWindow.off('windowStatusChange', this.windowStatusCb); } catch (e) {}
    }
    this.mainWindow = null;
    this.windowStatusCb = null;
  }

  /** Track the window mode so the floating tab bar inset follows it. Reads
   * the current mode once (the app may launch straight into a free window),
   * then subscribes to mode changes (API 12+ pair: getWindowStatus +
   * windowStatusChange, typed with WindowStatusType). Best-effort: any
   * failure just leaves the default 0 inset. */
  private watchWindowMode(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    window.getLastWindow(ctx).then((win) => {
      this.mainWindow = win;
      this.applyTabBarMargin(win.getWindowStatus());
      this.windowStatusCb = (status: window.WindowStatusType) => {
        this.applyTabBarMargin(status);
      };
      win.on('windowStatusChange', this.windowStatusCb);
    }).catch((e: BusinessError) => {
      hilog.warn(0x0001, TAG, `[TABS] getLastWindow fail: ${e.code} ${e.message}`);
    });
  }

  /** Store the mode and swap in a NEW modifier instance — assigning a fresh
   * @State reference forces the framework to re-run applyNormalAttribute with
   * the margin for the current mode. */
  private applyTabBarMargin(status: window.WindowStatusType): void {
    const margin = status === window.WindowStatusType.FLOATING
      ? TAB_BAR_BOTTOM_MARGIN_FLOATING
      : TAB_BAR_BOTTOM_MARGIN_DEFAULT;
    if (margin === this.lastAppliedMargin) return; // same value — no re-apply
    hilog.info(0x0001, TAG, `[TABS] windowStatus=${status} → barBottomMargin=${margin}`);
    this.lastAppliedMargin = margin;
    this.tabsModifier = new FloatingTabsModifier().setBarMargin(margin);
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
        .attributeModifier(this.tabsModifier)
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
