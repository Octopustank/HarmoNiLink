/**
 * GpsDispatcher.ets — TIME keep-alive ticker + event-driven GEO distribution
 *
 * Two decoupled rails (2026-08-30 power redesign, plans/gps-power-strategy.md):
 *   TIME rail — the ticker keeps its interval (foreground 1.5s / background
 *   5s) and sends ONLY TIME payloads: zero-cost link keep-alive, decoupled
 *   from GPS freshness.
 *   GEO rail — event-driven: one `on('locationChange')` subscription whose
 *   LocationRequest encodes the user-selected power mode
 *   (precise: 10s / 5m; power-saving: 300s / 50m). The system fires on
 *   movement or as an interval fallback — no polling, no GNSS wake-ups while
 *   stationary (power-saving) — and pushes coordinates straight through the
 *   existing staggeredWrite fan-out.
 *
 * The mode ("档位") is the only frequency control: no more implicit
 * foreground/background GEO interval switching. It persists via
 * PreferencesRepository and is applied here through setMode() (off+on
 * re-subscription in one place).
 *
 * Ready priming: after pairing/reconnect the first coordinate would
 * otherwise wait for the next subscription event (up to 10s precise /
 * 10min power-saving), so primeOnce() fetches one getCurrentLocation —
 * throttled by the mode's freshness window so repeated Ready events don't
 * over-fetch.
 *
 * geoHealth: every acquisition outcome (success/failure) is reported to the
 * Hub via onGeoResult for the SLA board's GREEN suppression logic.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { geoLocationManager } from '@kit.LocationKit';
import { Callback } from '@ohos.base';
import { GeoPayloadGenerator, GpsPosition } from '../ble/protocol/GeoPayloadGenerator';
import { TimePayloadGenerator } from '../ble/protocol/TimePayloadGenerator';
import { GpsData } from './GpsData';

const TAG = 'HarmoNiLink-GpsDispatcher';

// GPS phase stagger: with N cameras, space each camera's write by this many ms
// so they don't all grab the radio in the same millisecond. 200ms is
// comfortably below the 1.5s foreground tick.
const GPS_PHASE_STAGGER_MS = 200;

// Mode presets: timeInterval is the fallback-freshness bound (seconds),
// distanceInterval the movement trigger (meters). Values keep clear of the
// GNSS 1s / network 20s minimum-interval clamps.
// PRIORITY IS NOT OPTIONAL: with priority left undefined the system picks a
// low-power schedule where the 10s timeInterval fallback does not produce
// fixes for a stationary device indoors (measured: 65s without a single
// event while TIME kept flowing). precise uses FIRST_FIX — the same
// priority the pre-redesign getCurrentLocation polling used, which always
// yielded fresh fixes; power uses BALANCED so the 50m trigger has enough
// accuracy to fire without FIRST_FIX's duty cycle.
const GEO_PRECISE_INTERVAL_S = 10;
const GEO_PRECISE_DISTANCE_M = 5;
const GEO_POWER_INTERVAL_S = 300;
const GEO_POWER_DISTANCE_M = 50;

/** GPS sampling power mode (persisted in PreferencesRepository). */
export enum GpsPowerMode {
  PRECISE = 0, // 10s fallback / 5m trigger — freshness first
  POWER = 1,   // 300s fallback / 50m trigger — battery first
}

/** The slice of CameraSession the dispatcher writes to — an interface so this
 * module never imports the session class (no module cycle). */
export interface GpsWriteTarget {
  getCameraName(): string;
  writeTime(payload: Uint8Array): void;
  writeGeo(payload: Uint8Array): void;
}

export class GpsDispatcher {
  // GPS shared state — UI reads gpsData directly; the GEO rail (and priming)
  // fans out to all Ready targets.
  readonly gpsData: GpsData = new GpsData();
  // Real GNSS satellite count fed by Location Kit's satelliteStatusChange.
  lastSatelliteCount: number = -1;
  // Foreground/background flag — the TIME ticker picks its interval from it.
  isForeground: boolean = true;

  private getReadyTargets: () => GpsWriteTarget[];
  private onSlaYellow: (name: string) => void;
  private onGeoResult: (ok: boolean) => void;

  private mode: GpsPowerMode = GpsPowerMode.PRECISE;
  private gpsTimer: number | null = null;
  // GEO rail: one locationChange subscription per dispatcher, built while any
  // camera is Ready and torn down when the last one drops (an idling
  // subscription would still wake GNSS every interval — pure waste).
  private geoSubscribed: boolean = false;
  private locationCb: Callback<geoLocationManager.Location> | null = null;
  private locationErrorCb: Callback<geoLocationManager.LocationError> | null = null;
  // Prime dedupe: refreshGps() can fire several times in the same tick
  // (Ready event + toggle etc.) — one priming fix per burst is plenty.
  private lastPrimeAttemptTs: number = 0;

  // Satellite subscription state — process-wide constant, independent of the
  // power mode (see AGENTS.md reasoning + verification gate).
  private satelliteSubscribed: boolean = false;
  private satelliteStatusCb: ((status: geoLocationManager.SatelliteStatusInfo) => void) | null = null;

  constructor(getReadyTargets: () => GpsWriteTarget[],
    onSlaYellow: (name: string) => void,
    onGeoResult: (ok: boolean) => void) {
    this.getReadyTargets = getReadyTargets;
    this.onSlaYellow = onSlaYellow;
    this.onGeoResult = onGeoResult;
  }

  /** Start the ticker only if it isn't already running (no satellite reset).
   *  Also re-attempts the GEO subscription — if subscribeGeo() failed
   *  transiently inside start(), the running ticker alone would leave the
   *  GEO rail dead until an fg/bg transition. */
  ensureRunning(): void {
    if (this.gpsTimer !== null) {
      this.subscribeGeo(); // idempotent
      return;
    }
    this.start(1500);
  }

  start(intervalMs: number = 1500): void {
    const interval = this.isForeground ? intervalMs : 5000;
    hilog.info(0x0001, TAG, `[GPS] start: TIME interval=${interval}ms fg=${this.isForeground} mode=${this.mode}`);
    this.stop();
    // Idempotent retry: setContext() subscribes at startup, but location
    // permission may not be granted yet then (it's requested on first scan).
    // Re-attempt here (no-op if already subscribed).
    this.subscribeSatelliteStatus();
    this.subscribeGeo();
    // Immediate TIME — the link heartbeat starts right away.
    this.sendTick();
    this.gpsTimer = setInterval(() => { this.sendTick(); }, interval);
  }

  stop(): void {
    if (this.gpsTimer !== null) {
      clearInterval(this.gpsTimer);
      this.gpsTimer = null;
      hilog.info(0x0001, TAG, '[CHECKPOINT] GPS ticker stopped');
    }
    this.unsubscribeGeo();
    // Satellite subscription is independent of the ticker — do NOT reset
    // lastSatelliteCount here, so the satellite count survives camera drops.
  }

  /** Switch the GPS sampling mode: persist-free (caller persists), applies to
   *  the live subscription via off+on in one place. A dropped event at the
   *  switch instant is acceptable (next event follows the new cadence). */
  setMode(mode: GpsPowerMode): void {
    if (this.mode === mode) return;
    hilog.info(0x0001, TAG, `[GPS] mode -> ${mode === GpsPowerMode.PRECISE ? 'precise' : 'power'}`);
    this.mode = mode;
    if (this.geoSubscribed) {
      this.unsubscribeGeo();
      this.subscribeGeo();
    }
  }

  private geoRequest(): geoLocationManager.LocationRequest {
    return this.mode === GpsPowerMode.PRECISE
      ? { priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
          timeInterval: GEO_PRECISE_INTERVAL_S, distanceInterval: GEO_PRECISE_DISTANCE_M }
      : { priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
          timeInterval: GEO_POWER_INTERVAL_S, distanceInterval: GEO_POWER_DISTANCE_M };
  }

  private subscribeGeo(): void {
    if (this.geoSubscribed) return;
    try {
      this.locationCb = (location: geoLocationManager.Location) => {
        this.handleLocation(location);
      };
      geoLocationManager.on('locationChange', this.geoRequest(), this.locationCb);
      // Mark subscribed IMMEDIATELY: if the error-channel registration below
      // throws, the live locationChange closure must stay reachable for
      // off() — otherwise the next subscribeGeo() registers a duplicate and
      // every fix fans out twice.
      this.geoSubscribed = true;
      // Global error channel — events are NOT attributable to our session,
      // so degrade only on codes that actually kill our rail:
      //   -4 switch off / -2 permission denied  → rail dead, fail
      //   -3 background permission denied       → benign while foreground
      //                                            fixes keep working
      //   -1 default / -5 internet              → no evidence about our rail
      this.locationErrorCb = (err: geoLocationManager.LocationError) => {
        if (!this.geoSubscribed) return;
        const E = geoLocationManager.LocationError;
        const fatal = err === E.LOCATING_FAILED_LOCATION_SWITCH_OFF
          || err === E.LOCATING_FAILED_LOCATION_PERMISSION_DENIED;
        const bgDenied = err === E.LOCATING_FAILED_BACKGROUND_PERMISSION_DENIED;
        if (fatal || (bgDenied && !this.isForeground)) {
          hilog.warn(0x0001, TAG, `[GPS] locationError code=${err} — rail dead`);
          this.signalGeoFailure();
        } else {
          hilog.info(0x0001, TAG, `[GPS] locationError code=${err} — not ours, ignored`);
        }
      };
      geoLocationManager.on('locationError', this.locationErrorCb);
      hilog.info(0x0001, TAG, `[GPS] locationChange subscribed (${this.mode === GpsPowerMode.PRECISE ? 'precise' : 'power'})`);
    } catch (err) {
      this.geoSubscribed = false;
      this.locationCb = null;
      hilog.warn(0x0001, TAG, `[GPS] locationChange subscribe failed: ${JSON.stringify(err)}`);
    }
  }

  private unsubscribeGeo(): void {
    if (!this.geoSubscribed) return;
    try {
      if (this.locationCb !== null) {
        geoLocationManager.off('locationChange', this.locationCb);
      }
      if (this.locationErrorCb !== null) {
        geoLocationManager.off('locationError', this.locationErrorCb);
      }
      hilog.info(0x0001, TAG, '[GPS] locationChange unsubscribed');
    } catch (err) {
      hilog.warn(0x0001, TAG, `[GPS] locationChange unsubscribe failed: ${JSON.stringify(err)}`);
    }
    this.geoSubscribed = false;
    this.locationCb = null;
    this.locationErrorCb = null;
  }

  /** GEO distribution: one fix fans out to every Ready camera. */
  private handleLocation(location: geoLocationManager.Location): void {
    const targets = this.getReadyTargets();
    if (targets.length === 0) return;
    const lat = location.latitude;
    const lon = location.longitude;
    const alt = Math.round(location.altitude);
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
    hilog.info(0x0001, TAG, `[GPS] GEO event lat=${lat.toFixed(6)} lon=${lon.toFixed(6)} mode=${this.mode}`);
    this.onGeoResult(true); // geoHealth ok — GEO write confirmations feed SLA separately
    const payload = GeoPayloadGenerator.buildReal(gps);
    for (let i = 0; i < targets.length; i++) {
      this.staggeredWrite(targets[i], i, payload, false);
    }
  }

  /** One-shot fix after a camera becomes Ready (pairing/reconnect): without
   *  it the first GEO would wait for the next subscription event (10s
   *  precise / 5min power-saving worst case). ALWAYS primes — the phone
   *  having a recent fix says nothing about what THIS camera received —
   *  deduped only against same-burst re-invocations (3s). getCurrentLocation
   *  aggregates with the live subscription session, so the extra fetch is
   *  nearly free (plan §3). */
  primeOnce(): void {
    const now = Date.now();
    if (now - this.lastPrimeAttemptTs < 3000) {
      hilog.debug(0x0001, TAG, '[GPS] prime skipped — same burst');
      return;
    }
    this.lastPrimeAttemptTs = now;
    hilog.info(0x0001, TAG, '[GPS] priming fix (FIRST_FIX, 10s timeout)');
    try {
      geoLocationManager.getCurrentLocation({
        priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
        timeoutMs: 10000
      }).then((pos) => {
        this.onGeoResult(true); // geoHealth ok even if the camera dropped meanwhile
        if (this.getReadyTargets().length === 0) return;
        this.handleLocation(pos);
      }).catch(() => {
        hilog.debug(0x0001, TAG, '[GPS] prime skip — no location');
        this.signalGeoFailure();
      });
    } catch (e) {
      hilog.debug(0x0001, TAG, '[GPS] prime exception');
      this.signalGeoFailure();
    }
  }

  /** TIME-only ticker tick: pure link keep-alive, zero location cost. */
  private sendTick(): void {
    const ready = this.getReadyTargets();
    if (ready.length === 0) {
      this.stop();
      return;
    }
    const timePayload = TimePayloadGenerator.build();
    hilog.info(0x0001, TAG, `[GPS] TIME ${timePayload.length}B to ${ready.length} camera(s)`);
    for (let i = 0; i < ready.length; i++) {
      this.staggeredWrite(ready[i], i, timePayload, true);
    }
  }

  /** GPS acquisition failure path: SLA YELLOW event per camera (existing
   *  semantics); geoHealth=fail rides the onGeoResult channel. */
  private signalGeoFailure(): void {
    this.onGeoResult(false);
    this.signalSlaYellow(this.getReadyTargets());
  }

  /** Fan a YELLOW SLA signal (GPS no-fix / location-off) out to the given
   *  targets — GPS is a shared device source, so a no-fix degrades every
   *  connected camera at once. Same-sev repeats are no-ops in the tracker. */
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
      // isGnssServiceSupported is @since 26: guard with optional call so
      // devices on older SDK levels keep the legacy try/catch path.
      const gnssSupported = (geoLocationManager.isGnssServiceSupported as
        (() => boolean) | undefined)?.() ?? true;
      if (!gnssSupported) {
        hilog.info(0x0001, TAG, '[GPS] GNSS service unsupported — satellite count stays "--"');
        return;
      }
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
