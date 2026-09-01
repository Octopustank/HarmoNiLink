/**
 * RatingPrompt.ets — rating-prompt gates + direct system dialog
 *
 * Extracted from ConnectionPage. Fires on health-sheet close; prompts only
 * after the app has been TIME-TESTED and the CURRENT moment is healthy:
 *   G1 not permanently silenced (already-rated rejection / attempt cap)
 *   G2 a GEO write was ever acked
 *   G3 first ack ≥ 48h ago (absolute, not calendar days)
 *   G4 ≤ 3 RED-only cells in the 2h window (~≤6min total outage)
 *   G5 cooldown: ≥ 30 days since the last dialog that actually went up
 *   G6 fewer than 3 dialogs ever shown (cap — an unanswered user must not
 *      be nagged monthly forever)
 * v2.5.1 redesign: NO self-made two-button dialog before the system one —
 * the prompt jumps straight to commentManager.showCommentDialog and reads
 * the outcome (CommentDialog.onResult):
 *   'shown'        → cooldown + attempt count (rate vs dismiss is not
 *                    observable; the user WAS disturbed either way)
 *   'alreadyRated' → permanent silence (covers rating via 关于页 — the
 *                    market rejects and we silently stand down)
 *   'transient'    → NOTHING persisted: the dialog never appeared, so no
 *                    disturbance is owed — the next natural trigger retries.
 * Every failure is silent (hilog only) — marketing surfaces never toast.
 */
import { common, bundleManager } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { cameraService } from './CameraService';
import { SlaCell, SlaSev } from '../data/SlaTracker';
import { CommentDialog, RatingDialogOutcome } from '../components/CommentDialog';

const TAG = 'HarmoNiLink-RatingPrompt';

// Rating-prompt gates — tuned constants in one place.
const RATING_MIN_AGE_MS = 48 * 3600 * 1000;                // G3: first downlink ≥ 48h ago
const RATING_PROMPT_COOLDOWN_MS = 30 * 24 * 3600 * 1000;   // G5: 30 days after a dialog that went up
const RATING_MAX_ATTEMPTS = 3;                             // G6: 3 shown dialogs → permanent silence
const RATING_MAX_RED_CELLS = 3;                            // G4: 2h 窗口 RED-only 桶 ≤ 3

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
      const attempts = cameraService.getRatingAttempts();
      if (attempts >= RATING_MAX_ATTEMPTS) {
        // Cap reached once and for all — persist it so G1 answers faster.
        cameraService.markRatingShown();
        if (debug) hilog.info(0x0001, TAG, `[RATING] G6 not met — attempts=${attempts} (now permanent)`);
        return;
      }
      const lastTs = cameraService.getRatingLastTs();
      if (lastTs > 0 && now - lastTs < RATING_PROMPT_COOLDOWN_MS) {
        if (debug) hilog.info(0x0001, TAG, `[RATING] G5 not met — last dialog ${now - lastTs}ms ago`);
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
      CommentDialog.show(win.getUIContext(), true, (outcome: RatingDialogOutcome) => {
        if (outcome === 'shown') {
          cameraService.markRatingAttempt(Date.now());
        } else if (outcome === 'alreadyRated') {
          cameraService.markRatingShown(); // permanent — never disturb again
        }
        // 'transient' → persist nothing; the next natural trigger retries.
      });
    } catch (err) {
      hilog.warn(0x0001, TAG, 'rating prompt failed: ' + JSON.stringify(err));
    }
  }
}
