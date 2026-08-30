/**
 * DeviceHealthSheet.ets — 设备信息 + SLA 看板 half-modal content
 *
 * Extracted from ConnectionPage. Receives a FROZEN materialized snapshot
 * (slaCells) from the parent — never reads getSlaTimeline inside build: the
 * state listener would re-run it and shift the 2h window. The tapped-cell
 * tooltip state lives here, internal to the sheet.
 */
import { SlaCell, SlaSev } from '../data/SlaTracker';

@Component
export struct DeviceHealthSheet {
  @Prop cameraName: string = '';
  @Prop cameraAddress: string = '--';
  @Prop stateText: string = '--';
  @Prop slaCells: SlaCell[] = [];
  // Tooltip for the tapped cell — sheet-local state.
  @State tooltip: string = '';
  @State tooltipIndex: number = -1;

  private sevColor(sev: number): ResourceColor {
    if (sev === SlaSev.GREEN) return $r('app.color.success');
    if (sev === SlaSev.YELLOW) return $r('app.color.sla_light');
    if (sev === SlaSev.ORANGE) return $r('app.color.warning');
    if (sev === SlaSev.RED) return $r('app.color.danger');
    return $r('app.color.sla_grey');
  }

  private sevLabel(sev: number): string {
    if (sev === SlaSev.GREEN) return '连接正常';
    if (sev === SlaSev.YELLOW) return '偶发断连，数据已送达';
    if (sev === SlaSev.ORANGE) return '存在数据问题（无定位等）';
    if (sev === SlaSev.RED) return '完全中断，无数据';
    return '无下发活动';
  }

  /** Format an epoch-ms timestamp as HH:MM. */
  private timeLabel(ts: number): string {
    const d = new Date(ts);
    const hh = d.getHours().toString().padStart(2, '0');
    const mm = d.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private onCellTap(index: number): void {
    if (index < 0 || index >= this.slaCells.length) return;
    const cell = this.slaCells[index];
    this.tooltipIndex = index;
    this.tooltip = `${this.timeLabel(cell.startTs)}–${this.timeLabel(cell.endTs)} · ${this.sevLabel(cell.sev)}`;
  }

  /** One key-value row — tight content bounds on purpose (see GpsCard NOTE). */
  @Builder infoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(14).fontColor($r('app.color.text_secondary')).width(80)
      // Same tight-bounds rationale as GpsCard: layoutWeight(1) would make the
      // a11y/检测 box span the whole row (~98% empty) and skew pixel-based
      // contrast audits. constraintSize keeps content sizing for short values
      // while still capping long ones so maxLines+ellipsis works.
      Text(value).fontSize(14).fontColor($r('app.color.text_primary'))
        .constraintSize({ maxWidth: '100%' })
        .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
    }.width('100%').padding({ left: 16, right: 12, top: 10, bottom: 10 })
  }

  /** 60-cell static timeline bar (2min per cell over [now-2h, now]). */
  @Builder timelineBar() {
    Row() {
      ForEach(this.slaCells, (cell: SlaCell, i: number) => {
        Column()
          .height(24)
          .layoutWeight(1)
          .backgroundColor(this.sevColor(cell.sev))
          .borderRadius(1)
          .margin({ left: 0.5, right: 0.5 })
          .onClick(() => { this.onCellTap(i); })
      }, (cell: SlaCell) => `${cell.startTs}_${cell.sev}`)
    }
    .width('100%')
    .margin({ top: 12 })
  }

  /** 涂色说明 legend. */
  @Builder legend() {
    Column() {
      Row({ space: 6 }) {
        Row().width(8).height(8).borderRadius(4).backgroundColor($r('app.color.success'))
        Text('连接正常').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Row().width(8).height(8).borderRadius(4).backgroundColor($r('app.color.sla_light'))
        Text('偶发断连，但数据已送达').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Row().width(8).height(8).borderRadius(4).backgroundColor($r('app.color.warning'))
        Text('存在数据问题（无定位等）').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Row().width(8).height(8).borderRadius(4).backgroundColor($r('app.color.danger'))
        Text('完全中断，无数据').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
      Row({ space: 6 }) {
        Row().width(8).height(8).borderRadius(4).backgroundColor($r('app.color.sla_grey'))
        Text('无下发活动').fontSize(12).fontColor($r('app.color.text_secondary'))
      }.margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 12 })
  }

  build() {
    Column() {
      Text('设备信息').fontSize(22).fontWeight(FontWeight.Bold).margin({ top: 36 })

      Column() {
        this.infoRow('名称', this.cameraName)
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })
        this.infoRow('BLE 地址', this.cameraAddress)
        Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ left: 16, right: 12 })
        this.infoRow('状态', this.stateText)
      }
      .width('100%').borderRadius(16).backgroundColor($r('app.color.card_background'))
      .margin({ top: 24 })

      Column() {
        Text('过去 2 小时连接健康度').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        this.timelineBar()
        Row() {
          Text('2 小时前').fontSize(11).fontColor($r('app.color.text_secondary'))
          Blank()
          Text('现在').fontSize(11).fontColor($r('app.color.text_secondary'))
        }.width('100%').margin({ top: 4 })
        if (this.tooltip !== '') {
          Text(this.tooltip).fontSize(12).fontColor($r('app.color.text_primary')).margin({ top: 8 })
        }
        this.legend()
      }
      .width('100%').alignItems(HorizontalAlign.Start)
      .padding({ left: 16, right: 16, top: 12, bottom: 16 })
      .borderRadius(16).backgroundColor($r('app.color.card_background'))
      .margin({ top: 12 })

      Blank().layoutWeight(1)
    }
    .width('100%').height('100%').padding({ left: 16, right: 16 })
  }
}
