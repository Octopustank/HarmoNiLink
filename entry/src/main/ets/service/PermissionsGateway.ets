/**
 * PermissionsGateway.ets — on-demand runtime-permission requests
 *
 * Extracted from CameraService. Owns the permission lists and the
 * abilityAccessCtrl calls; the Hub exposes requestPermissionsIfNeeded() /
 * isBackgroundLocationGranted() / openBackgroundLocationSetting() as thin
 * delegations so pages keep their existing call sites.
 *
 * Permissions are requested in ONE batch (system queues the dialogs) on the
 * first user action (scan / connect) — never at app startup, so the
 * first-launch privacy dialog can't swallow them.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common, abilityAccessCtrl } from '@kit.AbilityKit';
import type { Permissions } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@kit.BasicServicesKit';

const TAG = 'HarmoNiLink-Permissions';

// User-grant permissions needed for scan/pair/connect. Requested in ONE batch
// (system queues the dialogs) on first user action, not at app startup.
const USER_GRANT_PERMISSIONS: Permissions[] = [
  'ohos.permission.ACCESS_BLUETOOTH',
  'ohos.permission.DISCOVER_BLUETOOTH',
  'ohos.permission.APPROXIMATELY_LOCATION',
  'ohos.permission.LOCATION',
];
// Must be requested AFTER LOCATION is granted; failure is non-fatal.
const BACKGROUND_LOCATION_PERMISSION: string = 'ohos.permission.LOCATION_IN_BACKGROUND';

export class PermissionsGateway {
  private getContext: () => common.UIAbilityContext | null;

  constructor(getContext: () => common.UIAbilityContext | null) {
    this.getContext = getContext;
  }

  async requestPermissionsIfNeeded(): Promise<boolean> {
    const ctx = this.getContext();
    if (!ctx) return false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const tokenId = ctx.applicationInfo.accessTokenId;
      const check = atManager.checkAccessTokenSync as Function;

      const needed: Permissions[] = [];
      for (let i = 0; i < USER_GRANT_PERMISSIONS.length; i++) {
        const permission = USER_GRANT_PERMISSIONS[i];
        if (check(tokenId, permission) !== 0) needed.push(permission);
      }
      if (needed.length === 0) return true;

      hilog.info(0x0001, TAG, `[PERM] requesting ${needed.length} permission(s): ${needed.join(', ')}`);
      const result = await atManager.requestPermissionsFromUser(ctx, needed);
      const authResults = result.authResults;

      let allGranted: boolean = true;
      for (let i = 0; i < authResults.length; i++) {
        if (authResults[i] !== 0) allGranted = false;
      }
      hilog.info(0x0001, TAG, `[PERM] batch result: ${authResults.join(', ')} allGranted=${allGranted}`);

      return allGranted;
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] request failed: ${JSON.stringify(err)}`);
      return false;
    }
  }

  isBackgroundLocationGranted(): boolean {
    const ctx = this.getContext();
    if (!ctx) return false;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const check = atManager.checkAccessTokenSync as Function;
      return check(ctx.applicationInfo.accessTokenId, BACKGROUND_LOCATION_PERMISSION) === 0;
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] background check error: ${JSON.stringify(err)}`);
      return false;
    }
  }

  openBackgroundLocationSetting(): void {
    const ctx = this.getContext();
    if (!ctx) return;
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const req = atManager.requestPermissionOnSetting as Function;
      req(ctx, [BACKGROUND_LOCATION_PERMISSION]).then((statuses: number[]) => {
        hilog.info(0x0001, TAG, `[PERM] on-setting result: ${statuses.join(', ')}`);
      }).catch((err: BusinessError) => {
        hilog.warn(0x0001, TAG, `[PERM] requestPermissionOnSetting failed: ${err.message}`);
      });
    } catch (err) {
      hilog.warn(0x0001, TAG, `[PERM] requestPermissionOnSetting exception: ${JSON.stringify(err)}`);
    }
  }
}
