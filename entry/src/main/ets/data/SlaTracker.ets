/**
 * SlaTracker.ets — Per-camera connection-health SLA timeline (看板)
 *
 * Data model — FIXED 60-cell ring buffer (2h = 60 × 2min), aligned to
 * ABSOLUTE 2-minute epoch buckets. A signal writes one bit into the slot that
 * owns its absolute bucket; materialize() reads the 60 visible buckets and
 * derives the color in one place. No open/close state machine, no variable
 * blocks, no dominant-overlap — thus NO temporal drift: the same absolute
 * 2-minute cell always yields the same color, regardless of when it is viewed.
 *
 * Per-cell flags (independent, persisted in the raw):
 *   GEO   : a GEO write was confirmed (full GPS downlink = healthy pair half)
 *   TIME  : a TIME write was confirmed (link alive; alone it is NOT "healthy")
 *   RED   : a link-level failure occurred (disconnected / cannot-connect /
 *            handshake-fail / write-fail — "完全挂了" evidence)
 *   YELLOW: a GPS no-fix / location-off / GEO-acquire-failure was observed
 *
 * Materialized color (decided HERE, never at sampling time):
 *   no downlink (GEO=0 AND TIME=0) AND red    -> RED   (完全挂了)
 *   no downlink AND no red                     -> GREY  (未开启/被杀/无采样)
 *   GEO=1 AND TIME=1 AND no red AND no yellow  -> GREEN (完整配对健康)
 *   anything else with any downlink            -> YELLOW (有下发但只有一味 /
 *                                             有 red(瞬时)/yellow 问题 — 最多黄不红)
 *
 * Sampling entry points (event-driven, NO timers, NO polling):
 *   onDownlink(now) : GEO confirmed -> set GEO bit
 *   onActivity(now) : TIME confirmed -> set TIME bit
 *   onSignal(now,sev) : YELLOW/RED -> set the matching bit (GREEN redirects to
 *                      onDownlink for call-site compatibility)
 *
 * Persistence — timestamp right-shift bucketing (coalesces disk writes):
 *   - downlink/activity persist on ~32.8s step (divisor 32768);
 *   - signal transitions persist on ~1s step (divisor 1024) so a RED survives
 *     a kill; first event always persists (bucket init -1); a backward bucket
 *     (clock skew) is skipped.
 *   Implemented with Math.floor division, NOT literal right-shift — ArkTS
 *   numbers are IEEE doubles, and bit-shift ToInt32-truncates the 42-bit
 *   epoch-ms timestamp, corrupting the bucket.
 *
 * Ring semantics: slot i owns bucket b where b ≡ i (mod 60). Writing a fresh
 * signal resets the slot if it currently holds a DIFFERENT (older) bucket.
 * The 60 slots therefore always mirror exactly the last 2h of real time,
 * newest-inclusive; a kill gap shows as "no slot for that bucket" -> GREY.
 *
 * Lifecycle:
 *   - load() restores lastSeen + slots; if-empty guarded so a live signal
 *     racing the async disk read is never overwritten. The (lastSeen, now]
 *     gap is left grey by bucket absence — the kill-resistance mechanism.
 *   - flush() is the unconditional last-line-of-defense persist for
 *     onAppBackground / onDestroy.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarmoNiLink-SlaTracker';

/** Window + cell geometry. */
const WIN_MS: number = 7200000;   // 2h
const CELL_MS: number = 120000;   // 2min
const CELL_COUNT: number = 60;
/** Persist-coalescing bucket divisors (2^15 ≈ 32.8s, 2^10 ≈ 1s). */
const DOWNLINK_STEP: number = 32768;
const SIGNAL_STEP: number = 1024;

export enum SlaSev {
  GREEN = 0,
  /** 轻微：偶发断连但该时段仍成功下发（宏观连接稳定，视觉近绿） */
  YELLOW = 1,
  /** 数据问题 / 多问题并存（GPS 无定位、只发出单一数据、断连+无定位） */
  ORANGE = 2,
  RED = 3,
  /** Inferred at materialize — never persisted. */
  GREY = 4,
}

/** One materialized timeline cell (2min, absolute-aligned). */
export interface SlaCell {
  startTs: number;
  endTs: number;
  sev: number; // SlaSev.* (GREY for no data)
}

/** One ring slot — the raw signal flags for a single absolute 2min bucket.
 * Persisted verbatim so a kill can be reconstructed from lastSeen forward. */
interface RingSlot {
  bucket: number;  // absolute bucket index this slot currently holds (-1 = empty)
  flags: number;   // bit0 GEO | bit1 TIME | bit2 RED | bit3 YELLOW
}

interface SlaSnapshot {
  lastSeen: number;
  slots: RingSlot[];
}

// Flag bits.
const F_GEO: number = 0b0001;
const F_TIME: number = 0b0010;
const F_RED: number = 0b0100;
const F_YELLOW: number = 0b1000;

export class SlaTracker {
  /** Ring slots indexed by (bucket mod 60). */
  private slots: RingSlot[] = [];
  // Last persisted/activity timestamp — the kill-gap anchor.
  private lastSeen: number = 0;
  // Persist-coalescing buckets (init -1 → first signal always persists).
  private lastDownlinkBucket: number = -1;
  private lastSignalBucket: number = -1;
  // Serialized-write sink (injected by the owner; prefs saveQueue in practice).
  private persist: (json: string) => void;

  constructor(persist: (json: string) => void) {
    this.persist = persist;
    for (let i = 0; i < CELL_COUNT; i++) {
      this.slots.push({ bucket: -1, flags: 0 });
    }
  }

  /** Absolute bucket for an epoch-ms timestamp. */
  private bucketOf(ts: number): number {
    return Math.floor(ts / CELL_MS);
  }

  /** The ring slot owning `bucket`. */
  private slotFor(bucket: number): RingSlot {
    return this.slots[((bucket % CELL_COUNT) + CELL_COUNT) % CELL_COUNT];
  }

  // ==================== Restore ====================

  /** Load a persisted snapshot. if-empty guarded: a live signal that already
   * opened slots must not be overwritten by (possibly stale) disk data. A kill
   * gap is NOT written — absent buckets render grey at materialize. */
  load(json: string | null): void {
    if (this.lastSeen > 0) return; // live activity already arrived — newer truth
    this.lastSeen = 0;
    this.lastDownlinkBucket = -1;
    this.lastSignalBucket = -1;
    for (let i = 0; i < CELL_COUNT; i++) {
      this.slots[i].bucket = -1;
      this.slots[i].flags = 0;
    }
    if (!json) return;
    try {
      const snap = JSON.parse(json) as SlaSnapshot;
      this.lastSeen = snap.lastSeen || 0;
      const raw = Array.isArray(snap.slots) ? snap.slots : [];
      for (let i = 0; i < raw.length && i < CELL_COUNT; i++) {
        const r = raw[i];
        if (r && typeof r.bucket === 'number' && r.bucket >= 0) {
          const b = Math.floor(r.bucket);
          const slot = this.slotFor(b);
          slot.bucket = b;
          slot.flags = r.flags;
        }
      }
    } catch (err) {
      hilog.warn(0x0001, TAG, 'load parse error: ' + JSON.stringify(err));
    }
  }

  // ==================== Signal entry points ====================

  /** Set a signal bit into the slot owning the absolute bucket of `now`.
   * Resets the slot first if it still holds an older bucket (ring rotation). */
  private mark(now: number, bit: number, fine: boolean): void {
    const bucket = this.bucketOf(now);
    const slot = this.slotFor(bucket);
    if (slot.bucket !== bucket) {
      slot.bucket = bucket; // stale older data — drop it, start fresh
      slot.flags = 0;
    }
    slot.flags |= bit;
    if (now > this.lastSeen) this.lastSeen = now;
    if (fine) {
      this.maybePersistSignal(now);
    } else {
      this.maybePersistDownlink(now);
    }
  }

  /** GEO write confirmed — the healthy "pair" half. High frequency. */
  onDownlink(now: number): void {
    this.mark(now, F_GEO, false);
  }

  /** TIME write confirmed — link alive but NO fix info (alone is never GREEN;
   * it only proves the link, matching "只有 TIME → 黄"). Never sets GEO. */
  onActivity(now: number): void {
    this.mark(now, F_TIME, false);
  }

  /** Low-freq anomaly/transition signal (sev = YELLOW | RED).
   * GREEN is redirected to onDownlink for call-site compatibility. */
  onSignal(now: number, sev: number): void {
    if (sev === SlaSev.GREEN) {
      this.onDownlink(now);
      return;
    }
    if (sev === SlaSev.RED) {
      this.mark(now, F_RED, true);
    } else { // YELLOW
      this.mark(now, F_YELLOW, true);
    }
  }

  /** Unconditional snapshot persist — onAppBackground / onDestroy. */
  flush(): void {
    this.persist(this.snapshotJson());
  }

  // ==================== Materialization ====================

  /** Materialize the 60 most recent absolute 2-min buckets into color cells.
   * Window is ABSOLUTE-aligned (bucket boundaries), so a given historical cell
   * always lands on the same slot and always gets the same color — the drift
   * fix. The newest bucket (containing `now`) is the live "in-progress" cell;
   * it may shift as it accrues flags — that is the expected real-time refresh.
   * Pure read, no side effects, deterministic. */
  materialize(now: number): SlaCell[] {
    const nowBucket = this.bucketOf(now);
    const firstBucket = nowBucket - (CELL_COUNT - 1);
    const cells: SlaCell[] = [];
    for (let i = 0; i < CELL_COUNT; i++) {
      const bucket = firstBucket + i;
      const slot = this.slotFor(bucket);
      const st = bucket * CELL_MS;
      const rawEnd = st + CELL_MS;
      cells.push({
        startTs: st,
        endTs: Math.min(rawEnd, now), // clamp the in-progress cell to now
        sev: this.decideSev(slot.bucket === bucket ? slot.flags : 0),
      });
    }
    return cells;
  }

  /** Color decision — the SINGLE place the semantics live, lightest→worst:
   *   GREEN  : GEO ∧ TIME ∧ no red no yellow (完整配对健康)
   *   YELLOW : has downlink ∧ red ∧ no yellow — 偶发断连但该时段成功下发，
   *            宏观连接稳定（轻，视觉上接近绿色）
   *   ORANGE : has downlink ∧ (yellow no red) — GPS 无定位等数据问题；
   *            or red ∧ yellow — 断连与数据问题并存
   *            or 只有单一数据（TIME-only / GEO-only）
   *   RED    : no downlink ∧ red — 彻底断开，一次都没发出
   *   GREY   : no downlink ∧ no red — 未开启 / 被杀 / 无采样 */
  private decideSev(flags: number): number {
    const hasGeo = (flags & F_GEO) !== 0;
    const hasTime = (flags & F_TIME) !== 0;
    const hasRed = (flags & F_RED) !== 0;
    const hasYellow = (flags & F_YELLOW) !== 0;
    const hasDown = hasGeo || hasTime;
    if (!hasDown) {
      return hasRed ? SlaSev.RED : SlaSev.GREY;
    }
    if (hasRed && hasYellow) return SlaSev.ORANGE;   // 两个问题并存
    if (hasRed) return SlaSev.YELLOW;                // 断连但成功下发
    if (hasYellow) return SlaSev.ORANGE;             // GPS 数据问题
    if (hasGeo && hasTime) return SlaSev.GREEN;      // 完整配对健康
    return SlaSev.ORANGE;                            // 只有单一数据（数据不完整）
  }

  // ==================== Internals ====================

  private maybePersistDownlink(now: number): void {
    const bucket = Math.floor(now / DOWNLINK_STEP);
    if (bucket < this.lastDownlinkBucket) return; // clock-backward — skip
    if (bucket === this.lastDownlinkBucket) return; // same bucket — coalesce
    this.lastDownlinkBucket = bucket;
    this.persistNow();
  }

  private maybePersistSignal(now: number): void {
    const bucket = Math.floor(now / SIGNAL_STEP);
    if (bucket < this.lastSignalBucket) return; // clock-backward — skip
    if (bucket === this.lastSignalBucket) return; // same bucket — coalesce
    this.lastSignalBucket = bucket;
    this.persistNow();
  }

  private persistNow(): void {
    this.persist(this.snapshotJson());
  }

  private snapshotJson(): string {
    const copy: RingSlot[] = [];
    for (const s of this.slots) copy.push({ bucket: s.bucket, flags: s.flags });
    return JSON.stringify({ lastSeen: this.lastSeen, slots: copy } as SlaSnapshot);
  }
}