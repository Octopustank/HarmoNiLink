/**
 * CommentDialog.ets — AppGallery rating dialog launcher (shared)
 *
 * The commentManager.showCommentDialog flow with its real-world error-code
 * map, shared by the 关于 sheet's 做个评价 row and the rating prompt's 去评分
 * button (both must behave identically).
 */
import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { commentManager } from '@kit.AppGalleryKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarmoNiLink-CommentDialog';

export class CommentDialog {
  static show(ui: UIContext): void {
    const ctx = ui.getHostContext() as common.UIAbilityContext;
    try {
      commentManager.showCommentDialog(ctx).then(() => {})
        .catch((e: BusinessError) => {
          // showCommentDialog fails in many situations. Two real-world groups:
          //  (A) account/state gating the user can act on (not signed in,
          //      already rated this version / within a year);
          //  (B) the app is NOT published on AppGallery — the dialog is backed
          //      by the market, which validates bundleName+versionCode; an
          //      unsigned/unlisted debug build has no market record, so it is
          //      rejected. That is a platform constraint, NOT a network error,
          //      so the fallback must NOT claim "check your network".
          // Surface a readable reason instead of swallowing it — "点了没反应"
          // is a bug report.
          const code = e ? e.code : 0;
          let msg = '无法打开评价：请确认应用已上架华为应用市场，并已登录华为账号';
          if (code === 1021500006) msg = '需要登录华为账号后才能评价';
          else if (code === 1021500007) msg = '你已对当前版本评价过了，感谢支持';
          else if (code === 1021500009) msg = '你一年内已评价过，感谢支持';
          else if (code === 1021500003) msg = '无法连接华为应用市场，请检查网络';
          else if (code === 1021500005) msg = '应用上下文无效，请重启应用后重试';
          ui.getPromptAction().showToast({ message: msg, duration: 2500 });
          hilog.warn(0x0001, TAG, 'showCommentDialog fail: code=' + code + ' msg=' + (e ? e.message : ''));
        });
    } catch (err) {
      hilog.warn(0x0001, TAG, 'showCommentDialog throw: ' + JSON.stringify(err));
      try {
        ui.getPromptAction().showToast({ message: '暂时无法打开评价', duration: 2500 });
      } catch (e) {
        hilog.warn(0x0001, TAG, `comment fallback toast err: ${(e as Error).message}`);
      }
    }
  }
}
