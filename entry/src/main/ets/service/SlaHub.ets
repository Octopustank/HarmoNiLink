/**
 * SlaHub.ets — per-camera connection-health tracker registry (连接健康看板)
 *
 * Extracted from CameraService. Owns one SlaTracker per camera, keyed by
 * camera name, lazily created on first signal and dropped on removeCamera.
 * Lives OUTSIDE CameraSession so the lifecycle survives session churn and can
 * be flushed on background/destroy independently of the BLE session.
 *
 * Also latches the global rating-prompt evidence: the first confirmed GEO
 * write marks hasDownlink + first_downlink_ts.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PreferencesRepository } from '../data/PreferencesRepository';
import { SlaTracker, SlaCell } from '../data/SlaTracker';

const TAG = 'HarmoNiLink-SlaHub';

export class SlaHub {
  private prefs: PreferencesRepository;
  // Per-camera SLA trackers — keyed by camera name, lazily created on first
  // signal, dropped on removeCamera.
  private trackers: Map<string, SlaTracker> = new Map();
  // In-flight persisted-SLA loads (per camera) — awaited by getTimelineLoaded
  // so the first info-sheet open never renders an empty bar due to async load.
  private loads: Map<string, Promise<void>> = new Map();

  constructor(prefs: PreferencesRepository) {
    this.prefs = prefs;
  }

  /** Get-or-create a camera's tracker. Lazily loads the persisted snapshot
   * (SlaTracker.load is if-empty guarded, so a live signal racing the async
   * read is never overwritten). */
  private getOrCreate(name: string): SlaTracker {
    let t = this.trackers.get(name);
    if (!t) {
      t = new SlaTracker((json: string): void => { this.prefs.saveSla(name, json); });
      this.trackers.set(name, t);
      // Track the async persisted load so the first info-sheet open can await
      // it (via getTimelineLoaded) instead of rendering an empty bar because
      // the disk read resolved a microtask later.
      const pending: Promise<void> = this.prefs.loadSla(name).then((json: string | null): void => {
        const cur = this.trackers.get(name);
        if (cur && json) cur.load(json);
      });
      this.loads.set(name, pending);
      pending.then((): void => {
        if (this.loads.get(name) === pending) this.loads.delete(name);
      });
    }
    return t;
  }

  /** GREEN signal — a GEO write was confirmed (full GPS downlink = has fix).
   * Latches the global `hasDownlink` evidence flag + `first_downlink_ts` (the
   * rating-prompt gates): a confirmed GEO write proves the pairing worked, and
   * the first-ack timestamp anchors the "used it long enough" 48h gate. */
  onDownlink(name: string): void {
    const now = Date.now();
    this.prefs.saveHasDownlink();
    this.prefs.saveFirstDownlinkTsIfZero(now);
    this.getOrCreate(name).onDownlink(now);
  }

  /** Activity marker — a TIME write was confirmed (fires regardless of fix;
   * never changes sev, only advances lastActivityAt for the gap rule). */
  onActivity(name: string): void {
    this.getOrCreate(name).onActivity(Date.now());
  }

  /** YELLOW/RED signal — an anomaly/transition for this camera. */
  onSignal(name: string, sev: number): void {
    this.getOrCreate(name).onSignal(Date.now(), sev);
  }

  /** Materialize a camera's timeline for the UI. Frozen snapshot — the caller
   * copies it into @State BEFORE showing the sheet (do NOT call inside a
   * @Builder: the state listener re-runs it and shifts the 2h window). */
  getTimeline(name: string): SlaCell[] {
    return this.getOrCreate(name).materialize(Date.now());
  }

  /** Materialize AFTER the persisted load settles — the first info-sheet open
   * renders the real history instead of an empty bar (async-load race). */
  async getTimelineLoaded(name: string): Promise<SlaCell[]> {
    const t = this.getOrCreate(name);
    const pending = this.loads.get(name);
    if (pending) {
      try { await pending; } catch (e) { /* best-effort */ }
    }
    return t.materialize(Date.now());
  }

  /** Drop one camera's tracker + persisted timeline (on removeCamera) — a
   * re-added camera must not inherit stale health history. */
  remove(name: string): void {
    this.trackers.delete(name);
    this.loads.delete(name);
    this.prefs.removeSla(name);
  }

  /** Clear every camera's persisted health timeline + in-memory trackers
   * (关于 → 删除连接健康度日志). Slots restart empty from the next signal. */
  clearAll(): void {
    this.trackers.clear();
    this.loads.clear();
    this.prefs.clearAllSla(); // per-key sweep incl. orphans, serialized
    hilog.info(0x0001, TAG, '[SLA] cleared all health timelines');
  }

  /** Unconditional flush of every camera's SLA — last line of defense against
   * an app kill (wired from onAppBackground + EntryAbility.onDestroy). */
  flushAll(): void {
    this.trackers.forEach((t: SlaTracker): void => { t.flush(); });
  }
}
