/**
 * GpsDispatcher.ets — single GPS ticker fanned out to Ready sessions
 *
 * Extracted from CameraService. Owns the ONE location source and the ONE
 * ticker: alternating TIME/GEO writes, per-camera phase staggering, foreground
 * / background interval switching, and the GNSS satellite-count subscription.
 *
 * The Hub supplies the current write targets (Ready sessions, as
 * GpsWriteTarget) and the SLA-yellow outlet (GPS is a shared device source —
 * a no-fix degrades every connected camera at once).
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { geoLocationManager } from '@kit.LocationKit';
import { GeoPayloadGenerator, GpsPosition } from '../ble/protocol/GeoPayloadGenerator';
import { TimePayloadGenerator } from '../ble/protocol/TimePayloadGenerator';
import { GpsData } from './GpsData';

const TAG = 'HarmoNiLink-GpsDispatcher';

// GPS phase stagger: with N cameras, space each camera's write by this many ms
// so they don't all grab the radio in the same millisecond (Phase 2 power/
// scheduling strategy). 200ms is comfortably below the 1500ms foreground tick.
const GPS_PHASE_STAGGER_MS = 200;

/** The slice of CameraSession the dispatcher writes to — an interface so this
 * module never imports the session class (no module cycle). */
export interface GpsWriteTarget {
  getCameraName(): string;
  writeTime(payload: Uint8Array): void;
  writeGeo(payload: Uint8Array): void;
}

export class GpsDispatcher {
  // GPS shared state — UI reads gpsData directly; the single ticker below
  // fans out to all Ready targets.
  readonly gpsData: GpsData = new GpsData();
  // Real GNSS satellite count fed by Location Kit's satelliteStatusChange.
  lastSatelliteCount: number = -1;
  // Foreground/background flag — the ticker picks its interval from it.
  isForeground: boolean = true;

  private getReadyTargets: () => GpsWriteTarget[];
  private onSlaYellow: (name: string) => void;
  // Invoked whenever a (re)start happens — the Hub reconciles the
  // ContinuousTask there (a running ticker implies a Ready camera implies
  // the task must be up).
  private onLoopStarted: () => void;

  private gpsTimer: number | null = null;
  private gpsStep: number = 0; // 0=TIME, 1=GEO — alternating

  // Satellite subscription state — single location source.
  private satelliteSubscribed: boolean = false;
  private satelliteStatusCb: ((status: geoLocationManager.SatelliteStatusInfo) => void) | null = null;

  constructor(getReadyTargets: () => GpsWriteTarget[],
    onSlaYellow: (name: string) => void,
    onLoopStarted: () => void) {
    this.getReadyTargets = getReadyTargets;
    this.onSlaYellow = onSlaYellow;
    this.onLoopStarted = onLoopStarted;
  }

  /** Start the ticker only if it isn't already running (no satellite reset). */
  ensureRunning(): void {
    if (this.gpsTimer !== null) return;
    this.start(1500);
  }

  start(intervalMs: number = 1500): void {
    const interval = this.isForeground ? intervalMs : 5000;
    hilog.info(0x0001, TAG, `[GPS] start: interval=${interval}ms fg=${this.isForeground}`);
    this.stop();
    // Idempotent retry: setContext() subscribes at startup, but location
    // permission may not be granted yet then (it's requested on first scan).
    // Re-attempt here (no-op if already subscribed).
    this.subscribeSatelliteStatus();
    this.gpsStep = 0;
    // Send TIME immediately, then alternate TIME/GEO
    this.sendTick();
    this.gpsTimer = setInterval(() => { this.sendTick(); }, interval);
    this.onLoopStarted();
  }

  stop(): void {
    if (this.gpsTimer !== null) {
      clearInterval(this.gpsTimer);
      this.gpsTimer = null;
      hilog.info(0x0001, TAG, '[CHECKPOINT] GPS loop stopped');
    }
    // Satellite subscription is independent of the ticker — do NOT reset
    // lastSatelliteCount here, so the satellite count survives camera drops.
  }

  private sendTick(): void {
    const ready = this.getReadyTargets();
    if (ready.length === 0) {
      this.stop();
      return;
    }
    if (this.gpsStep === 0) {
      const timePayload = TimePayloadGenerator.build();
      hilog.info(0x0001, TAG, `[GPS] TIME ${timePayload.length}B to ${ready.length} camera(s)`);
      for (let i = 0; i < ready.length; i++) {
        this.staggeredWrite(ready[i], i, timePayload, true);
      }
      this.gpsStep = 1;
    } else {
      this.gpsStep = 0;
      // Check if location service is enabled
      try {
        const locEnabled = geoLocationManager.isLocationEnabled?.() ?? true;
        if (!locEnabled) {
          hilog.warn(0x0001, TAG, '[GPS] Location service disabled, skip GEO');
          this.signalSlaYellow(ready); // SLA YELLOW: location off
          return;
        }
      } catch (e) { /* proceed anyway */ }

      try {
        geoLocationManager.getCurrentLocation({
          priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
          timeoutMs: 5000
        }).then((pos) => {
          const stillReady = this.getReadyTargets();
          if (stillReady.length === 0) return;
          // Update shared GPS state
          const lat = pos.latitude;
          const lon = pos.longitude;
          const alt = Math.round(pos.altitude);
          const sats = this.lastSatelliteCount;
          this.gpsData.hasFix = true;
          this.gpsData.latitude = lat;
          this.gpsData.longitude = lon;
          this.gpsData.altitude = alt;
          this.gpsData.satellites = sats;
          this.gpsData.lastUpdateTime = new Date().toLocaleTimeString();

          const gps: GpsPosition = {
            latitude: lat, longitude: lon, altitude: alt,
            satellites: sats >= 0 ? sats : 6, timestamp: new Date()
          };
          hilog.info(0x0001, TAG, `[GPS] GEO real lat=${lat.toFixed(6)} lon=${lon.toFixed(6)}`);
          const payload = GeoPayloadGenerator.buildReal(gps);
          for (let i = 0; i < stillReady.length; i++) {
            this.staggeredWrite(stillReady[i], i, payload, false);
          }
        }).catch(() => {
          hilog.debug(0x0001, TAG, '[GPS] GEO skip — no location');
          this.signalSlaYellow(this.getReadyTargets()); // SLA YELLOW: GPS no-fix
        });
      } catch (e) {
        hilog.debug(0x0001, TAG, '[GPS] GEO skip — exception');
        this.signalSlaYellow(this.getReadyTargets()); // SLA YELLOW: GPS no-fix (sync throw)
      }
    }
  }

  /** Fan a YELLOW SLA signal (GPS no-fix / location-off) out to the given
   * targets — GPS is a shared device source, so a no-fix degrades every
   * connected camera at once. Same-sev repeats are no-ops in the tracker. */
  private signalSlaYellow(targets: GpsWriteTarget[]): void {
    for (let i = 0; i < targets.length; i++) {
      const name = targets[i].getCameraName();
      if (name !== '') this.onSlaYellow(name);
    }
  }

  /**
   * Fan a write out to one camera, staggered by its index so N cameras don't
   * all transmit in the same instant. Writes are self-guarding (BleClient
   * drops them if the link is gone), so a delayed write after a disconnect is
   * harmless.
   */
  private staggeredWrite(target: GpsWriteTarget, index: number, payload: Uint8Array, isTime: boolean): void {
    const delay = index * GPS_PHASE_STAGGER_MS;
    const doWrite = (): void => {
      if (isTime) { target.writeTime(payload); } else { target.writeGeo(payload); }
    };
    if (delay === 0) {
      doWrite();
    } else {
      setTimeout(doWrite, delay);
    }
  }

  /** Subscribe to the GNSS satellite-count stream — idempotent. Called once at
   * startup (Hub.setContext) and re-attempted on every ticker start (location
   * permission may only be granted after the first user action). */
  subscribeSatelliteStatus(): void {
    if (this.satelliteSubscribed) return;
    try {
      this.satelliteStatusCb = (status: geoLocationManager.SatelliteStatusInfo) => {
        if (status.satellitesNumber >= 0) {
          this.lastSatelliteCount = status.satellitesNumber;
        }
      };
      geoLocationManager.on('satelliteStatusChange', this.satelliteStatusCb);
      this.satelliteSubscribed = true;
      hilog.info(0x0001, TAG, '[GPS] subscribed to satelliteStatusChange');
    } catch (err) {
      this.satelliteSubscribed = false;
      this.satelliteStatusCb = null;
      hilog.warn(0x0001, TAG, `[GPS] satelliteStatusChange subscribe failed: ${JSON.stringify(err)}`);
    }
  }
}
