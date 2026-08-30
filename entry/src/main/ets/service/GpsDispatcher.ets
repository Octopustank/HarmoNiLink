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
 * LIFECYCLE DECOUPLING (重连 ≠ 定位): the GEO subscription is gated by USER
 * INTENT — alive while any paired camera's connection toggle is ON, torn
 * down when the user turned every switch off or removed the camera. Link
 * drops NEVER tear it down: a stationary device yields no callbacks (AND
 * semantics ≈ zero cost); a moving one keeps gpsData/geoHealth fresh so
 * that when a camera reconnects, writeCachedGps() pushes the LATEST
 * position over BLE (zero GNSS cost). Only a mode switch re-subscribes
 * (parameters changed).
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

// Mode presets — the SINGLE source of truth for all three sampling modes:
// LocationRequest parameters, the geoHealth freshness window (2x
// timeInterval) consumed by SlaTracker.decideSev, and UI copy.
// PRIORITY IS NOT OPTIONAL: with priority left undefined the system picks a
// low-power schedule where the 10s timeInterval fallback does not produce
// fixes for a stationary device indoors (measured: 65s without a single
// event while TIME kept flowing).
// Values keep clear of the GNSS 1s / network 20s minimum-interval clamps.
export interface GpsModePreset {
  priority: geoLocationManager.LocationRequestPriority;
  timeIntervalS: number;
  distanceM: number;
  /** geoHealth freshness window (2x timeInterval). */
  maxGeoIntervalMs: number;
  label: string;
  /** Shown when the user switches to this mode. */
  toast: string;
}

/** GPS sampling mode (persisted in PreferencesRepository). */
export enum GpsMode {
  REALTIME = 0, // FIRST_FIX, 10s / distance 0 — always the latest fix (原版手感)
  SMART = 1,    // FIRST_FIX, 120s / 20m — movement triggers, stationary fallback
  RELAXED = 2,  // LOW_POWER, 300s / 100m — network fixes, ballpark, most savings
}

export const GPS_MODE_PRESETS: GpsModePreset[] = [
  {
    priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
    timeIntervalS: 10, distanceM: 0, maxGeoIntervalMs: 10000,
    label: '实时',
    toast: '已切换到实时：卫星定位，约 10 秒更新一次（最耗电）',
  },
  {
    priority: geoLocationManager.LocationRequestPriority.FIRST_FIX,
    timeIntervalS: 120, distanceM: 20, maxGeoIntervalMs: 120000,
    label: '智能省电',
    toast: '已切换到智能省电：走动约 20 米即更新，静止约 2 分钟一次',
  },
  {
    priority: geoLocationManager.LocationRequestPriority.LOW_POWER,
    timeIntervalS: 300, distanceM: 100, maxGeoIntervalMs: 600000,
    label: '粗略省电',
    toast: '已切换到粗略省电：网络定位，约 10 分钟保底一次（最省电）',
  },
];

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

  private mode: GpsMode = GpsMode.REALTIME;
  private gpsTimer: number | null = null;
  // GEO rail: one APP-RESIDENT locationChange subscription, gated by USER
  // INTENT — alive while any paired camera's connection toggle is ON
  // (setGeoIntent), torn down when the user turned every switch off or the
  // camera was removed (无意图零定位). Link drops NEVER touch it (重连 ≠ 定位);
  // only intent loss or a mode switch (parameters changed) re-subscribes.
  private geoSubscribed: boolean = false;
  private locationCb: Callback<geoLocationManager.Location> | null = null;
  private locationErrorCb: Callback<geoLocationManager.LocationError> | null = null;
  // Timestamp of the last SUCCESSFUL GPS acquisition — the geoHealth-driven
  // fallback fetch in sendTick() measures its freshness window against it.
  private lastGeoOkTs: number = 0;
  // Fallback sampling: the subscription's timeInterval fallback does NOT fire
  // for a stationary device (measured: distanceInterval acts as an AND filter
  // — drift below the threshold suppresses callbacks even after many
  // intervals). The ticker therefore tops up one getCurrentLocation whenever
  // the last successful fix is older than the mode's freshness window.
  private lastGeoAttemptTs: number = 0;
  // Written-coordinate dedupe across the two GEO channels (subscription event
  // + fallback fetch can deliver the same physical fix): skip the BLE write
  // when the position moved <~1.1m within 3s — UI/geoHealth still update.
  private lastWrittenLat: number = 999;
  private lastWrittenLon: number = 999;
  private lastWrittenTs: number = 0;
  private lastCachedWriteTs: number = 0;

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

  /** geoHealth freshness window of the active mode (2x timeInterval). */
  private maxGeoIntervalMs(): number {
    return GPS_MODE_PRESETS[this.mode].maxGeoIntervalMs;
  }

  /** Single reporting funnel: keep lastGeoOkTs fresh on success, then hand
   *  the outcome to the Hub (SlaHub broadcasts to every tracker). */
  private reportGeo(ok: boolean): void {
    if (ok) this.lastGeoOkTs = Date.now();
    this.onGeoResult(ok);
  }

  start(intervalMs: number = 1500): void {
    const interval = this.isForeground ? intervalMs : 5000;
    hilog.info(0x0001, TAG, `[GPS] start: TIME interval=${interval}ms fg=${this.isForeground} mode=${GPS_MODE_PRESETS[this.mode].label}`);
    this.stop();
    // Idempotent retry: setContext() subscribes at startup, but location
    // permission may not be granted yet then (it's requested on first scan).
    // Re-attempt here (no-op if already subscribed).
    this.subscribeSatelliteStatus();
    this.subscribeGeo(); // idempotent — repairs a transiently failed subscribe
    // No cached fix yet (fresh install / first connection): fetch one so the
    // camera gets coordinates immediately instead of waiting for an event.
    if (!this.gpsData.hasFix) {
      this.fetchOnce();
    }
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
    // GEO subscription stays ALIVE across link drops (订阅与重连解耦):
    // stationary it never fires (AND semantics ≈ zero cost); while moving it
    // keeps gpsData/geoHealth fresh so a reconnecting camera receives the
    // LATEST position, not a stale one. Torn down only by setMode()'s
    // off+on re-subscription.
    // Satellite subscription is independent of the ticker — do NOT reset
    // lastSatelliteCount here, so the satellite count survives camera drops.
  }

  /** USER-INTENT gate for the GEO subscription (订阅生命周期钉在意图上):
   *  alive while any paired camera's connection toggle is ON — link drops
   *  never tear it down, so the 2min inactivity disconnect/reconnect cycle
   *  keeps its zero-GNSS-reconnect benefit. Intent gone (all switches off /
   *  camera removed) → unsubscribe (无意图零定位, the pre-redesign
   *  semantics). Idempotent; permission-less first runs fail silently and
   *  are repaired by start()'s ensure + this gate on the next toggle. */
  setGeoIntent(active: boolean): void {
    if (active) {
      this.subscribeGeo();
    } else {
      this.unsubscribeGeo();
    }
  }

  /** Switch the GPS sampling mode: persist-free (caller persists), applies to
   *  the live subscription via off+on in one place. A dropped event at the
   *  switch instant is acceptable (next event follows the new cadence). */
  setMode(mode: GpsMode): void {
    if (this.mode === mode) return;
    hilog.info(0x0001, TAG, `[GPS] mode -> ${GPS_MODE_PRESETS[mode].label}`);
    this.mode = mode;
    if (this.geoSubscribed) {
      this.unsubscribeGeo();
      this.subscribeGeo();
    }
  }

  private geoRequest(): geoLocationManager.LocationRequest {
    const preset = GPS_MODE_PRESETS[this.mode];
    return {
      priority: preset.priority,
      timeInterval: preset.timeIntervalS,
      distanceInterval: preset.distanceM,
    };
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
      hilog.info(0x0001, TAG, `[GPS] locationChange subscribed (${GPS_MODE_PRESETS[this.mode].label})`);
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

  /** Subscription callback: record the acquisition, refresh the shared GPS
   *  state, then fan the fix out (fanOutGps dedupes and distributes). */
  private handleLocation(location: geoLocationManager.Location): void {
    this.reportGeo(true); // acquisition-level fact — recorded even if no camera is Ready
    this.gpsData.hasFix = true;
    this.gpsData.satellites = this.lastSatelliteCount;
    this.fanOutGps(location.latitude, location.longitude, Math.round(location.altitude));
  }

  /** Distribute one fix (from any channel) to every Ready camera, with
   *  cross-channel dedupe: the fallback fetch and the subscription can
   *  deliver the same physical fix — skip the BLE write when the position
   *  barely moved within 3s (gpsData/geoHealth above still update). */
  private fanOutGps(lat: number, lon: number, alt: number): void {
    this.gpsData.latitude = lat;
    this.gpsData.longitude = lon;
    this.gpsData.altitude = alt;
    this.gpsData.lastUpdateTime = new Date().toLocaleTimeString();
    const targets = this.getReadyTargets();
    if (targets.length === 0) return; // no consumer — gpsData stays fresh for the next Ready
    hilog.info(0x0001, TAG, `[GPS] GEO out lat=${lat.toFixed(6)} lon=${lon.toFixed(6)} mode=${GPS_MODE_PRESETS[this.mode].label}`);
    const nearDupe = Math.abs(lat - this.lastWrittenLat) < 1e-5
      && Math.abs(lon - this.lastWrittenLon) < 1e-5
      && (Date.now() - this.lastWrittenTs) < 3000;
    this.lastWrittenLat = lat;
    this.lastWrittenLon = lon;
    this.lastWrittenTs = Date.now();
    if (nearDupe) return;
    const sats = this.gpsData.satellites;
    const gps: GpsPosition = {
      latitude: lat, longitude: lon, altitude: alt,
      satellites: sats >= 0 ? sats : 6, timestamp: new Date()
    };
    const payload = GeoPayloadGenerator.buildReal(gps);
    for (let i = 0; i < targets.length; i++) {
      this.staggeredWrite(targets[i], i, payload, false);
    }
  }

  /** Reconnect recovery (重连 ≠ 定位): push the CACHED latest fix to every
   *  Ready camera over BLE — zero GNSS cost. The app-resident subscription
   *  kept it fresh while the link was down, so a camera reconnecting after
   *  the user walked around receives the position where the USER is now.
   *  DELAYED 2.5s after Ready: the camera rejects 0x2007 (2900099-class)
   *  while its GPS session wakes — writing in the Ready instant just burns
   *  a rejection. Burst-guard 30s: a reconnect loop must not multiply
   *  cache writes (the GEO-failure path no longer tears the link down, but
   *  neither should it hammer a waking camera). */
  writeCachedGps(): void {
    if (!this.gpsData.hasFix) return;
    const now = Date.now();
    if (now - this.lastCachedWriteTs < 30000) return;
    this.lastCachedWriteTs = now;
    setTimeout(() => {
      hilog.info(0x0001, TAG, `[GPS] cached fix -> Ready cameras (lat=${this.gpsData.latitude.toFixed(6)})`);
      this.fanOutGps(this.gpsData.latitude, this.gpsData.longitude, this.gpsData.altitude);
    }, 2500);
  }

  /** Ticker tick: TIME keep-alive (zero location cost) + a geoHealth-driven
   *  fallback fetch. The locationChange subscription is the main GEO channel
   *  but its timeInterval fallback does not fire for a stationary device
   *  (distanceInterval acts as an AND filter) — so whenever the last
   *  successful fix is older than the mode's freshness window, this tick
   *  fetches one getCurrentLocation. That implements plan §4's freshness
   *  floor: at most ONE extra fetch per window (20s/120s/600s by mode). */
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
    const now = Date.now();
    if (now - this.lastGeoOkTs >= this.maxGeoIntervalMs()
      && now - this.lastGeoAttemptTs >= this.maxGeoIntervalMs()) {
      this.lastGeoAttemptTs = now;
      this.fetchOnce();
    }
  }

  /** One-shot fallback acquisition (10s): priority follows the active mode
   *  preset — a RELAXED (LOW_POWER) subscription must not be "topped up" by
   *  a FIRST_FIX fetch that would wake GNSS anyway. Same distribution path
   *  as the subscription callback; failure feeds geoHealth + SLA YELLOW. */
  private fetchOnce(): void {
    const preset = GPS_MODE_PRESETS[this.mode];
    hilog.info(0x0001, TAG, `[GPS] fallback fetch (${preset.label}, 10s timeout)`);
    try {
      geoLocationManager.getCurrentLocation({
        priority: preset.priority,
        timeoutMs: 10000
      }).then((pos) => {
        this.onGeoResult(true);
        this.handleLocation(pos);
      }).catch(() => {
        hilog.debug(0x0001, TAG, '[GPS] fallback skip — no location');
        this.signalGeoFailure();
      });
    } catch (e) {
      hilog.debug(0x0001, TAG, '[GPS] fallback exception');
      this.signalGeoFailure();
    }
  }

  /** GPS acquisition failure path: SLA YELLOW event per camera (existing
   *  semantics); geoHealth=fail rides the onGeoResult channel. */
  private signalGeoFailure(): void {
    this.reportGeo(false);
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
