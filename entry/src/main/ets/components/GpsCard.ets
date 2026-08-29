/**
 * GpsCard.ets — always-present GPS info card (global @Builder)
 *
 * Extracted from ConnectionPage. Stable layout, no jump on connect/disconnect.
 * The status light is ALWAYS visible (grey = nothing connected, yellow =
 * acquiring / connecting, green = heartbeat running with a fix). Stateless
 * layout, so it is a global @Builder (DevEco perf rule: few-use, stateless UI
 * belongs to @Builder, not custom components); the parent passes a plain
 * params object refreshed on every parent re-render.
 */

/** What the status light should express — parent derives it from live state. */
export enum GpsLightState {
  /** Nothing connected — grey. */
  OFF = 0,
  /** Some camera connecting / acquiring — yellow. */
  BUSY = 1,
  /** A Ready camera, but no GPS fix yet — yellow "正在获取". */
  ACQUIRING = 2,
  /** A Ready camera with a fix — green "定位下发中". */
  DOWNLINK = 3,
}

export interface GpsCardParams {
  controllerName: string;
  lat: string;
  lon: string;
  alt: string;
  sats: string;
  time: string;
  lightState: number;
}

function lightColor(state: number): ResourceColor {
  if (state === GpsLightState.DOWNLINK) return $r('app.color.success');
  if (state === GpsLightState.BUSY || state === GpsLightState.ACQUIRING) {
    return $r('app.color.warning');
  }
  return $r('app.color.text_secondary');
}

function lightLabel(state: number): string {
  if (state === GpsLightState.DOWNLINK) return '定位下发中';
  if (state === GpsLightState.ACQUIRING) return '正在获取';
  if (state === GpsLightState.BUSY) return '正在连接';
  return '未连接';
}

@Builder
function GpsInfoRow(label: string, value: string) {
  Row() {
    Text(label).fontSize(13).fontColor($r('app.color.text_secondary')).width(64)
    // NOTE: no layoutWeight(1) here on purpose — a layoutWeight'd Text owns the
    // whole remaining row width, so its a11y/检测 bounding box is ~98% empty
    // background. Pixel-based contrast auditors then average background with a
    // few white pixels and report a bogus ratio (1.52) even though the real
    // glyph contrast is ~12–14:1 (white #E6FFFFFF on card #2A2A2A). Content-
    // sized bounds keep the measured box on the glyphs themselves.
    Text(value).fontSize(13).fontColor($r('app.color.text_primary'))
  }.width('100%').padding({ top: 2, bottom: 2 })
}

@Builder
export function GpsCard(params: GpsCardParams) {
  Column() {
    Row() {
      Text('GPS 信息').fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
      Blank()
      Circle({ width: 8, height: 8 }).fill(lightColor(params.lightState))
      Text(lightLabel(params.lightState)).fontSize(11).fontColor(lightColor(params.lightState)).margin({ left: 6 })
    }.width('100%').margin({ bottom: 10 })
    GpsInfoRow('配对名称', params.controllerName)
    Divider().strokeWidth(0.5).color($r('app.color.divider')).margin({ top: 4, bottom: 6 })
    GpsInfoRow('纬度', params.lat)
    GpsInfoRow('经度', params.lon)
    GpsInfoRow('海拔', params.alt)
    GpsInfoRow('卫星数', params.sats)
    GpsInfoRow('更新时间', params.time)
  }
  .width('100%').alignItems(HorizontalAlign.Start)
  .padding({ left: 16, right: 16, top: 12, bottom: 16 })
  .borderRadius(16).backgroundColor($r('app.color.card_background'))
  .shadow({ radius: 12, color: '#0D000000', offsetY: 2 })
  .margin({ top: 12 })
}
