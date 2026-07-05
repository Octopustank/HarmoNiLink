/**
 * GpsData.ets — Shared GPS state object
 *
 * @Observed enables ArkUI reactivity: UI auto-updates when fields change.
 * CameraService writes, Index reads — no callback needed.
 */
@Observed
export class GpsData {
  latitude: number = 0;
  longitude: number = 0;
  altitude: number = 0;
  satellites: number = 0;
  hasFix: boolean = false;
  lastUpdateTime: string = '--';
}
