/**
 * AboutSheet.ets — 关于 half-modal content (global @Builder)
 *
 * Extracted from ConnectionPage. App icon/name + settings-style rows:
 * 应用版本 / 开源协议 / 开源仓库 / 做个评价 / 删除连接健康度日志 / 重置引导.
 * Pure layout — every action is a callback into the parent (which owns the
 * UIContext for dialogs/toasts/links and resets shared sheet state).
 */

export interface AboutSheetParams {
  appVersion: string;
  onLicense: () => void;
  onRepo: () => void;
  onComment: () => void;
  /** 关于 → 删除连接健康度日志 — the parent clears SLA state + shows its own
   * confirm dialog, so the destructive flow stays with the page. */
  onClearSla: () => void;
  onReset: () => void;
}

@Builder
function AboutActionRow(label: string, onTap: () => void) {
  Row() {
    Text(label).fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
    SymbolGlyph($r('sys.symbol.chevron_right')).fontSize(18).fontColor([$r('app.color.text_secondary')])
  }
  .width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })
  .borderRadius(16)
  .stateStyles({
    pressed: { .backgroundColor($r('app.color.press_feedback')) },
    normal: { .backgroundColor(Color.Transparent) }
  })
  .onClick(() => { onTap(); })
}

@Builder
function AboutRowDivider() {
  Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })
}

@Builder
export function AboutSheet(params: AboutSheetParams) {
  Column() {
    Image($r('app.media.app_icon')).width(72).height(72).borderRadius(18).margin({ top: 36 })
    Text('NiLink').fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 14 })
    Text('HarmoNiLink').fontSize(13).fontColor($r('app.color.text_secondary')).margin({ top: 2 })

    Column() {
      Row() {
        Text('应用版本').fontSize(16).fontColor($r('app.color.text_primary')).layoutWeight(1)
        Text(params.appVersion).fontSize(14).fontColor($r('app.color.text_secondary'))
      }.width('100%').padding({ left: 16, right: 12, top: 14, bottom: 14 })

      AboutRowDivider()
      AboutActionRow('开源协议', params.onLicense)
      AboutRowDivider()
      AboutActionRow('开源仓库', params.onRepo)
      AboutRowDivider()
      AboutActionRow('做个评价', params.onComment)
      AboutRowDivider()
      AboutActionRow('删除连接健康度日志', params.onClearSla)
      AboutRowDivider()
      AboutActionRow('重置引导', params.onReset)
    }
    .width('100%').borderRadius(16).backgroundColor($r('app.color.card_background'))
    .margin({ top: 32, bottom: 24 })

    Blank().layoutWeight(1)
  }
  .width('100%').height('100%').padding({ left: 16, right: 16 })
}
