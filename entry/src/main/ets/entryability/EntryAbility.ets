/**
 * EntryAbility.ets — Main UIAbility for HarmoNiLink
 *
 * Handles:
 *   - Permission requests at startup
 *   - Loading pages/Index
 *   - Lifecycle logging for debugging
 *
 * [CHECKPOINT] Every lifecycle event is logged via HiLog.
 */

import { AbilityConstant, UIAbility, Want, abilityAccessCtrl, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'HarmoNiLink-EntryAbility';

const REQUIRED_PERMISSIONS: string[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.USE_BLUETOOTH',
  'ohos.permission.DISCOVER_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION',
  'ohos.permission.LOCATION_IN_BACKGROUND',
  'ohos.permission.KEEP_BACKGROUND_RUNNING',
];

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] EntryAbility.onCreate()');
  }

  onDestroy(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] EntryAbility.onDestroy()');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onWindowStageCreate()');

    this.requestPermissions();

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
  }

  onBackground(): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onBackground()');
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0001, TAG, '[CHECKPOINT] onNewWant()');
  }

  // ==================== Permission Handling ====================

  private requestPermissions(): void {
    const atManager = abilityAccessCtrl.createAtManager();
    const ctx = this.context as common.UIAbilityContext;
    const tokenId = ctx.applicationInfo.accessTokenId;

    const perms: string[] = REQUIRED_PERMISSIONS;
    for (let i = 0; i < perms.length; i++) {
      const permission = perms[i];
      this.checkAndRequest(atManager, ctx, tokenId, permission);
    }
  }

  private checkAndRequest(
    atManager: abilityAccessCtrl.AtManager,
    ctx: common.UIAbilityContext,
    tokenId: number,
    permission: string
  ): void {
    try {
      // Use the override that accepts string to bypass the Permissions union type
      const check = atManager.checkAccessTokenSync as Function;
      const granted = check(tokenId, permission) === 0;
      if (granted) {
        hilog.info(0x0001, TAG, `[CHECKPOINT] Permission already granted: ${permission}`);
        return;
      }
      hilog.info(0x0001, TAG,
        `[CHECKPOINT] Permission needed: ${permission} — requesting...`);
      const req = atManager.requestPermissionsFromUser as Function;
      req(ctx, [permission]).then((result: Record<string, Object>) => {
        hilog.info(0x0001, TAG,
          `[CHECKPOINT] Permission result for ${permission}: auth=${result['authResults']}`);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0001, TAG,
          `[CHECKPOINT] Permission request failed for ${permission}: ${err.message}`);
      });
    } catch (err) {
      hilog.warn(0x0001, TAG,
        `[CHECKPOINT] Permission check error for ${permission}: ${JSON.stringify(err)}`);
    }
  }
}
