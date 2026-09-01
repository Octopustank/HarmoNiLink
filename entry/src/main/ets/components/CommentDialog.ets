/**
 * CommentDialog.ets — AppGallery rating dialog launcher (shared)
 *
 * commentManager.showCommentDialog with its real-world error-code map,
 * shared by two callers with deliberately different failure semantics:
 *  - 关于 sheet's 做个评价 row (silent=false): the user tapped the button, so
 *    a silent failure reads as "点了没反应" — surface a readable toast.
 *  - the rating prompt (silent=true): a MARKETING surface — failures must
 *    never toast. Outcomes report back via onResult so the prompt can persist
 *    its cooldown / permanent-silence state.
 */
import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { commentManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarmoNiLink-CommentDialog';

/** What happened to one showCommentDialog attempt:
 *  - 'shown': the system dialog went up (user rated OR dismissed — the API
 *    does not distinguish; both mean the user WAS disturbed → cooldown);
 *  - 'alreadyRated': market rejected with its already-rated code — the user
 *    will never see the dialog again → permanent silence;
 *  - 'transient': network / sign-in / context errors — the user saw nothing,
 *    so no cooldown is owed; the next natural trigger may retry freely. */
export type RatingDialogOutcome = 'shown' | 'alreadyRated' | 'transient';

// Market error codes that mean "already rated" (current version / within a
// year) — the two rejections that convert the prompt to permanent silence.
const CODE_ALREADY_RATED_VERSION = 1021500007;
const CODE_ALREADY_RATED_YEAR = 1021500009;

export class CommentDialog {
  static show(ui: UIContext, silent: boolean, onResult?: (o: RatingDialogOutcome) => void): void {
    const ctx = ui.getHostContext() as common.UIAbilityContext;
    try {
      commentManager.showCommentDialog(ctx).then(() => {
        onResult?.('shown');
      }).catch((e: BusinessError) => {
        // showCommentDialog fails in many situations. Two real-world groups:
        //  (A) account/state gating the user can act on (not signed in,
        //      already rated this version / within a year);
        //  (B) the app is NOT published on AppGallery — the dialog is backed
        //      by the market, which validates bundleName+versionCode; an
        //      unsigned/unlisted debug build has no market record, so it is
        //      rejected. That is a platform constraint, NOT a network error,
        //      so the fallback must NOT claim "check your network".
        const code = e ? e.code : 0;
        hilog.warn(0x0001, TAG, 'showCommentDialog fail: code=' + code + ' msg=' + (e ? e.message : ''));
        if (code === CODE_ALREADY_RATED_VERSION || code === CODE_ALREADY_RATED_YEAR) {
          onResult?.('alreadyRated');
          return;
        }
        onResult?.('transient');
        if (!silent) {
          // User-initiated: surface a readable reason instead of swallowing
          // it — "点了没反应" is a bug report.
          let msg = '无法打开评价：请确认应用已上架华为应用市场，并已登录华为账号';
          if (code === 1021500006) msg = '需要登录华为账号后才能评价';
          else if (code === 1021500007) msg = '你已对当前版本评价过了，感谢支持';
          else if (code === 1021500009) msg = '你一年内已评价过，感谢支持';
          else if (code === 1021500003) msg = '无法连接华为应用市场，请检查网络';
          else if (code === 1021500005) msg = '应用上下文无效，请重启应用后重试';
          ui.getPromptAction().showToast({ message: msg, duration: 2500 });
        }
      });
    } catch (err) {
      hilog.warn(0x0001, TAG, 'showCommentDialog throw: ' + JSON.stringify(err));
      onResult?.('transient');
      if (!silent) {
        try {
          ui.getPromptAction().showToast({ message: '暂时无法打开评价', duration: 2500 });
        } catch (e) {
          hilog.warn(0x0001, TAG, `comment fallback toast err: ${(e as Error).message}`);
        }
      }
    }
  }
}
