/**
 * SlaTracker.ets — Per-camera connection-health SLA timeline (看板)
 *
 * A per-camera event-driven state machine that records the past 2h of
 * connection health as a list of interval blocks, then materializes them into
 * a fixed 60-cell timeline bar (2min per cell).
 *
 * Data model — three states + inferred grey:
 *   sev 0 = GREEN  : downlink active, no anomaly
 *   sev 1 = YELLOW : downlink active but degraded (GPS no-fix / location off)
 *   sev 2 = RED    : link failure (disconnected / cannot-connect / handshake-fail)
 *   GREY is NOT persisted — it is inferred at materialize time as "no interval
 *   covers this cell" (not connected / app killed / no sampling).
 *
 * State machine — event-driven, NO timers, NO polling:
 *   - onDownlink(now)      : high-freq "successful write confirmed" entry.
 *     Closes the open block and opens a fresh GREEN block when (a) recovering
 *     from a non-GREEN block, or (b) the gap since last activity exceeds 60s
 *     (the silent stretch then renders grey via non-coverage).
 *   - onSignal(now, sev)   : low-freq anomaly/transition entry. Closes+opens a
 *     block only when sev CHANGES; same-sev repeats are no-ops (no block churn).
 *
 * Persistence — timestamp right-shift bucketing (coalesces disk writes):
 *   - sev transitions persist on ~1s step (ts >> 10) so a RED survives a kill;
 *   - same-sev repeats + downlink persist on ~32.8s step (ts >> 15) so a long
 *     GPS-no-fix stretch does not flush preferences every tick.
 *   Bucket init -1 → first signal always persists; a backward bucket (clock
 *   skew) is skipped. NOTE: implemented with Math.floor division, NOT the
 *   literal `>>` operator — ArkTS numbers are IEEE doubles and `>>` ToInt32-
 *   truncates the 42-bit epoch-ms timestamp, which corrupts the bucket.
 *
 * Lifecycle:
 *   - only the last 2h of intervals are kept (trim + adjacent same-sev merge on
 *     every snapshot);
 *   - load() restores blocks + lastSeen; the (lastSeen, now] gap is left grey
 *     (never written) — this is the kill-resistance mechanism (no onDestroy
 *     settlement needed);
 *   - flush() is the unconditional last-line-of-defense persist for
 *     onAppBackground / onDestroy.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarmoNiLink-SlaTracker';

/** Window + cell geometry. */
const WIN_MS: number = 7200000;   // 2h
const CELL_MS: number = 120000;   // 2min
const CELL_COUNT: number = 60;
/** Downlink gap that closes a GREEN block and renders the stretch grey. */
const GAP_MS: number = 60000;
/** Bucket step divisors (2^15 ≈ 32.8s, 2^10 ≈ 1s). */
const DOWNLINK_STEP: number = 32768;
const SIGNAL_STEP: number = 1024;

export enum SlaSev {
  GREEN = 0,
  YELLOW = 1,
  RED = 2,
  /** Inferred at materialize — never persisted. */
  GREY = 3,
}

/** A persisted interval block. Within an interval, sev is monotonically
 * non-decreasing; worsening OR recovery closes the block and opens a new one. */
export interface SlaBlock {
  s: number; // startTs (epoch ms)
  e: number; // endTs (epoch ms)
  sev: number; // SlaSev.GREEN | YELLOW | RED
}

/** One materialized timeline cell (2min). */
export interface SlaCell {
  startTs: number;
  endTs: number;
  sev: number; // SlaSev.* (GREY for no coverage)
}

interface SlaSnapshot {
  lastSeen: number;
  blocks: SlaBlock[];
}

export class SlaTracker {
  // Closed blocks (ordered by s, non-overlapping, s < e, e <= lastSeen).
  private blocks: SlaBlock[] = [];
  // The currently-open block (endTs advances lazily; persisted as endTs=lastSeen).
  private openBlock: SlaBlock | null = null;
  // Last persisted/activity timestamp — the kill-gap anchor.
  private lastSeen: number = 0;
  // Last successful-downlink timestamp (drives the 60s gap rule).
  private lastActivityAt: number = 0;
  // Persist-coalescing buckets (init -1 → first signal always persists).
  private lastDownlinkBucket: number = -1;
  private lastSignalBucket: number = -1;
  // Serialized-write sink (injected by the owner; prefs saveQueue in practice).
  private persist: (json: string) => void;

  constructor(persist: (json: string) => void) {
    this.persist = persist;
  }

  // ==================== Restore ====================

  /** Load a persisted snapshot. The (lastSeen, now] gap is intentionally NOT
   * written as grey — it is inferred at materialize. If the last persisted
   * block was an open GREEN block (e === lastSeen), resume it so a sub-60s
   * kill gap is absorbed into the same block (consistent with the live rule). */
  load(json: string | null): void {
    // if-empty guard: the async disk read may return AFTER a live signal has
    // already opened a block — never overwrite in-memory activity with stale
    // disk data (the fresh activity is the newer truth).
    if (this.lastSeen > 0 || this.openBlock !== null || this.blocks.length > 0) return;
    this.blocks = [];
    this.openBlock = null;
    this.lastSeen = 0;
    this.lastActivityAt = 0;
    this.lastDownlinkBucket = -1;
    this.lastSignalBucket = -1;
    if (!json) return;
    try {
      const snap = JSON.parse(json) as SlaSnapshot;
      this.lastSeen = snap.lastSeen || 0;
      // Drop inverted blocks (endTs < startTs) — residue from a pre-fix
      // closeOpen(lastActivityAt) bug that inverted the red block on a slow
      // reconnect. They'd otherwise paint a spurious red cell.
      const raw: SlaBlock[] = snap.blocks || [];
      const blks: SlaBlock[] = raw.filter((b: SlaBlock): boolean => b.e >= b.s);
      if (blks.length > 0) {
        const last = blks[blks.length - 1];
        if (last.sev === SlaSev.GREEN && last.e === this.lastSeen) {
          this.openBlock = last;      // resume the open green block
          this.blocks = blks.slice(0, -1);
        } else {
          this.blocks = blks;
        }
      }
      this.lastActivityAt = this.lastSeen;
    } catch (err) {
      hilog.warn(0x0001, TAG, `load parse error: ${JSON.stringify(err)}`);
    }
  }

  // ==================== Signal entry points ====================

  /** Successful downlink (a TIME/GEO write was confirmed). High frequency. */
  onDownlink(now: number): void {
    const open = this.openBlock;
    if (open === null) {
      this.openBlock = this.makeBlock(now, SlaSev.GREEN);
    } else if (open.sev !== SlaSev.GREEN) {
      // Recovery from a degraded/broken block.
      this.closeOpen(now);
      this.openBlock = this.makeBlock(now, SlaSev.GREEN);
    } else if (now - this.lastActivityAt > GAP_MS) {
      // Silent stretch >60s: close the old block at the last known activity so
      // the gap renders grey, then open a fresh green block at now.
      this.closeOpen(this.lastActivityAt);
      this.openBlock = this.makeBlock(now, SlaSev.GREEN);
    } else {
      // Contiguous activity — extend the current block.
      open.e = now;
    }
    this.lastActivityAt = now;
    this.lastSeen = now;
    this.maybePersistDownlink(now);
  }

  /** TIME-write activity marker. A TIME write succeeds regardless of GPS fix,
   * so it is NOT a GREEN recovery signal for a YELLOW block — treating it as
   * one would flicker GREEN/YELLOW every tick while the GPS has no fix. But a
   * RED block means the link was DOWN, and a successful TIME write proves the
   * link is back, so RED → recover to GREEN. */
  onActivity(now: number): void {
    const open = this.openBlock;
    if (open === null) {
      this.openBlock = this.makeBlock(now, SlaSev.GREEN);
    } else if (open.sev === SlaSev.RED) {
      // Link recovered: close the red block at `now` (NOT lastActivityAt —
      // lastActivityAt froze at the last successful write BEFORE the outage,
      // i.e. < the red block's start; closing there would invert the block).
      this.closeOpen(now);
      this.openBlock = this.makeBlock(now, SlaSev.GREEN);
    } else if (open.sev === SlaSev.YELLOW) {
      // GPS fix still unknown (TIME does not imply a fix) — keep YELLOW, just
      // extend; the next GEO success will recover to GREEN.
      open.e = now;
    } else {
      // GREEN — the 60s gap rule: a long silent stretch closes at the last
      // activity (gap renders grey) and reopens GREEN.
      if (now - this.lastActivityAt > GAP_MS) {
        this.closeOpen(this.lastActivityAt);
        this.openBlock = this.makeBlock(now, SlaSev.GREEN);
      } else {
        open.e = now; // contiguous activity — extend
      }
    }
    this.lastActivityAt = now;
    this.lastSeen = now;
    this.maybePersistDownlink(now);
  }

  /** Low-freq anomaly/transition signal (sev = YELLOW | RED). */
  onSignal(now: number, sev: number): void {
    if (sev === SlaSev.GREEN) {
      this.onDownlink(now);
      return;
    }
    const open = this.openBlock;
    const changed = open === null || open.sev !== sev;
    if (changed) {
      if (open !== null) this.closeOpen(now);
      this.openBlock = this.makeBlock(now, sev);
      this.lastSeen = now;
      // Transitions persist at fine granularity so a RED survives a kill.
      this.maybePersistSignal(now);
    } else {
      // Same-sev repeat — no block churn; just advance the watermark and
      // persist on the coarse bucket (a long no-fix stretch must not flush
      // preferences every tick).
      open.e = now;
      this.lastSeen = now;
      this.maybePersistDownlink(now);
    }
  }

  /** Unconditional snapshot persist — onAppBackground / onDestroy. */
  flush(): void {
    const now = Date.now();
    this.trim(now);
    this.persist(this.snapshotJson());
  }

  // ==================== Materialization ====================

  /** Materialize [now-2h, now] into CELL_COUNT cells. A cell's sev is the
   * DOMINANT block — the one overlapping it for the longest time. A 2s drop
   * inside a cell that is otherwise healthy stays green (it is not "no downlink
   * at all"); a cell covered mostly by a red block paints red. Ties resolve to
   * the more severe block. GREY only when no block overlaps at all.
   * Deterministic — pure read, no side effects. */
  materialize(now: number): SlaCell[] {
    const winStart = now - WIN_MS;
    const cells: SlaCell[] = [];
    for (let i = 0; i < CELL_COUNT; i++) {
      cells.push({ startTs: winStart + i * CELL_MS, endTs: winStart + (i + 1) * CELL_MS, sev: SlaSev.GREY });
    }
    // Collect all blocks (closed + open) for overlap lookup. Ordered by s.
    const all: SlaBlock[] = [];
    for (const b of this.blocks) all.push(b);
    if (this.openBlock !== null) {
      all.push({ s: this.openBlock.s, e: this.lastSeen, sev: this.openBlock.sev });
    }
    for (let i = 0; i < CELL_COUNT; i++) {
      const cellStart = cells[i].startTs;
      const cellEnd = cells[i].endTs;
      let bestSev = -1;
      let bestDur = 0;
      for (let j = 0; j < all.length; j++) {
        const b = all[j];
        if (b.e <= b.s) continue; // skip inverted blocks (historical bug residue)
        const ovStart = b.s > cellStart ? b.s : cellStart;
        const ovEnd = b.e < cellEnd ? b.e : cellEnd;
        if (ovStart >= ovEnd) continue; // no overlap
        const dur = ovEnd - ovStart;
        if (dur > bestDur || (dur === bestDur && b.sev > bestSev)) {
          bestDur = dur;
          bestSev = b.sev;
        }
      }
      if (bestSev >= 0) cells[i].sev = bestSev;
    }
    return cells;
  }

  // ==================== Internals ====================

  private makeBlock(at: number, sev: number): SlaBlock {
    return { s: at, e: at, sev };
  }

  /** Close the open block at `at` and append it to the closed list. */
  private closeOpen(at: number): void {
    if (this.openBlock === null) return;
    this.openBlock.e = at;
    this.blocks.push(this.openBlock);
    this.openBlock = null;
  }

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
    const now = Date.now();
    this.trim(now);
    this.persist(this.snapshotJson());
  }

  /** Drop blocks older than 2h and merge adjacent same-sev blocks (caps block
   * count against flicker and keeps the JSON KB-scale). */
  private trim(now: number): void {
    const cutoff = now - WIN_MS;
    const kept: SlaBlock[] = [];
    for (const b of this.blocks) {
      if (b.e > cutoff) kept.push(b);
    }
    // Merge adjacent same-sev blocks.
    const merged: SlaBlock[] = [];
    for (const b of kept) {
      const prev = merged.length > 0 ? merged[merged.length - 1] : null;
      if (prev !== null && prev.sev === b.sev) {
        prev.e = b.e;
      } else {
        merged.push({ s: b.s, e: b.e, sev: b.sev });
      }
    }
    this.blocks = merged;
  }

  private snapshotJson(): string {
    const all: SlaBlock[] = [];
    for (const b of this.blocks) all.push({ s: b.s, e: b.e, sev: b.sev });
    if (this.openBlock !== null) {
      // Persist the open block with endTs = lastSeen so load() can resume it.
      all.push({ s: this.openBlock.s, e: this.lastSeen, sev: this.openBlock.sev });
    }
    return JSON.stringify({ lastSeen: this.lastSeen, blocks: all } as SlaSnapshot);
  }
}
