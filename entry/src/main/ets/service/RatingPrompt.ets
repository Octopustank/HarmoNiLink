/**
 * RatingPrompt.ets — rating-prompt gates (G1–G5) + dialog
 *
 * Extracted from ConnectionPage. Fires on health-sheet close; prompts only
 * after the app has been TIME-TESTED and the CURRENT moment is healthy:
 *   G1 not already tapped 去评分 (permanent)
 *   G2 a GEO write was ever acked
 *   G3 first ack ≥ 48h ago (absolute, not calendar days)
 *   G4 ≤ 3 RED-only cells in the 2h window (~≤6min total outage)
 *   G5 never declined, or declined ≥ 7 days ago (cooldown, not permanent)
 * 谢绝/dismiss writes declined_at (re-prompt after cooldown); 去评分 writes
 * rating_shown (permanent — market already rate-limits 1/year). debug → toast
 * + per-gate hilog; release → 2-button dialog. Best-effort: any failure is
 * silent (hilog), never a misleading toast.
 */
import { common, bundleManager } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cameraService } from './CameraService';
import { SlaCell, SlaSev } from '../data/SlaTracker';
import { CommentDialog } from '../components/CommentDialog';

const TAG = 'HarmoNiLink-RatingPrompt';

// Rating-prompt gates — tuned constants in one place.
const RATING_MIN_AGE_MS = 48 * 3600 * 1000;              // G3: first downlink ≥ 48h ago
const RATING_DECLINE_COOLDOWN_MS = 7 * 24 * 3600 * 1000; // G5: 谢绝冷却 7 天
const RATING_MAX_RED_CELLS = 3;                          // G4: 2h 窗口 RED-only 桶 ≤ 3

export class RatingPrompt {
  /** True when the current build is a debug (unsigned/unlisted) HAP — the
   * rating prompt then only toasts (AppGallery can't validate a debug build). */
  private static isDebugBuild(): boolean {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      return info.appInfo.debug;
    } catch (e) {
      return false; // fail-safe: treat as release
    }
  }

  /** G4 input: count RED-only cells (完全断连) in the current camera's 2h
   * window. Awaits the persisted load so a cold-start open-then-close can't
   * under-count RED while the disk merge is still in flight (which would make
   * G4 pass on a not-yet-loaded, all-grey timeline). */
  private static async countRedCells(infoCameraName: string): Promise<number> {
    const cells: SlaCell[] = await cameraService.getSlaTimelineLoaded(infoCameraName);
    let red = 0;
    for (const c of cells) {
      if (c.sev === SlaSev.RED) red++;
    }
    return red;
  }

  static async maybePrompt(ctx: common.UIAbilityContext, infoCameraName: string): Promise<void> {
    try {
      const now = Date.now();
      const debug = RatingPrompt.isDebugBuild();

      if (cameraService.wasRatingShown()) {
        if (debug) hilog.info(0x0001, TAG, '[RATING] G1 not met — already tapped 去评分');
        return;
      }
      if (!cameraService.hasDownlink()) {
        if (debug) hilog.info(0x0001, TAG, '[RATING] G2 not met — no downlink yet');
        return;
      }
      const firstTs = cameraService.getFirstDownlinkTs();
      if (firstTs <= 0 || now - firstTs < RATING_MIN_AGE_MS) {
        if (debug) hilog.info(0x0001, TAG, `[RATING] G3 not met — age=${firstTs > 0 ? now - firstTs : -1}ms`);
        return;
      }
      const redCells = await RatingPrompt.countRedCells(infoCameraName);
      if (redCells > RATING_MAX_RED_CELLS) {
        if (debug) hilog.info(0x0001, TAG, `[RATING] G4 not met — red=${redCells}`);
        return;
      }
      const declinedAt = cameraService.getDeclinedAt();
      if (declinedAt > 0 && now - declinedAt < RATING_DECLINE_COOLDOWN_MS) {
        if (debug) hilog.info(0x0001, TAG, `[RATING] G5 not met — declined ${now - declinedAt}ms ago`);
        return;
      }

      if (debug) {
        // Debug: toast only (AppGallery can't validate an unsigned build); log
        // the inputs so each gate can be verified on-device.
        hilog.info(0x0001, TAG, `[RATING] all gates passed — firstTs=${firstTs} red=${redCells}`);
        const win0 = await window.getLastWindow(ctx);
        win0.getUIContext().getPromptAction().showToast({ message: '评分弹窗触发（debug 验证）', duration: 2000 });
        return;
      }

      const win = await window.getLastWindow(ctx);
      win.getUIContext().getPromptAction().showDialog({
        title: '给个评价吧',
        message: '如果你觉得 HarmoNiLink 好用，欢迎到华为应用市场给个评价。',
        buttons: [
          { text: '谢绝', color: $r('app.color.text_secondary') },
          { text: '去评分', color: $r('app.color.brand') }
        ]
      }).then((result) => {
        if (result.index === 1) {
          cameraService.markRatingShown(); // 去评分 → permanent
          CommentDialog.show(win.getUIContext()); // shared flow (self try/catch + code map)
        } else {
          cameraService.markDeclined(); // 谢绝 → cooldown
        }
      }).catch(() => {
        cameraService.markDeclined(); // dismissed/back → treat as declined (cooldown)
      });
    } catch (err) {
      hilog.warn(0x0001, TAG, 'rating prompt failed: ' + JSON.stringify(err));
    }
  }
}
