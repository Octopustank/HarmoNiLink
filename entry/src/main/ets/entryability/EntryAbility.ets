/**
 * EntryAbility.ets — Main UIAbility for HarmoNiLink
 *
 * Handles:
 *   - Loading pages/MainPage
 *   - Lifecycle logging for debugging
 *
 * Permission requests moved out of startup: they are now requested on
 * first user action (scan / reconnect) via CameraService.requestPermissionsIfNeeded(),
 * so the first-launch system privacy dialog no longer swallows them.
 *
 * [CHECKPOINT] Every lifecycle event is logged via HiLog.
 */

import { AbilityConstant, UIAbility, Want, bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { cameraService } from '../service/CameraService';

const TAG = 'HarmoNiLink-EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0001, TAG, `[CHECKPOINT] EntryAbility.onCreate()`);
    // Initialize the service EARLY (before MainPage renders) so the async
    // prefs.load has time to finish — MainPage then reads the persisted tab
    // index synchronously without flashing the wrong tab.
    cameraService.setContext(this.context);
    this.logAppVersion();
  }

  onDestroy(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] EntryAbility.onDestroy()');
    cameraService.flushSlaAll(); // last line of defense against app kill
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onWindowStageCreate()');

    windowStage.loadContent('pages/MainPage', async (err: BusinessError) => {
      if (err.code) {
        hilog.error(0x0001, TAG,
          `[CHECKPOINT] loadContent FAILED: code=${err.code} msg=${err.message}`);
        return;
      }
      hilog.info(0x0001, TAG, '[CHECKPOINT] loadContent OK');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onWindowStageDestroy()');
  }

  onForeground(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onForeground()');
    cameraService.onAppForeground();
  }

  onBackground(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onBackground()');
    cameraService.onAppBackground();
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onNewWant()');
  }

  // ==================== Version ====================

  private logAppVersion(): void {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      hilog.info(0x0001, TAG,
        `══════════════ NiLink v${info.versionName} (${info.versionCode}) ══════════════`);
    } catch (e) {
      hilog.warn(0x0001, TAG, `[CHECKPOINT] BundleInfo read failed: ${JSON.stringify(e)}`);
    }
  }
}
