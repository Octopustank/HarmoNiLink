/**
 * BackgroundTaskKeeper.ets — ContinuousTask lifecycle keeper
 *
 * Extracted from CameraService. Owns the ONE ContinuousTask (notification-
 * bearing long-running task) that keeps the process alive for background GPS
 * writes and keep-alive reconnects:
 *   - start/stop/update racing guards (bgGeneration vs async start()),
 *   - dynamic mode tracking (bluetoothInteraction [+ location when Ready]),
 *   - system cancel/suspend listeners (the task can be revoked silently),
 *   - silent-revocation inference on warm foreground return,
 *   - the one-per-interrupt foreground notice dialog.
 *
 * The Hub feeds it three facts: the UIAbility context, how many sessions are
 * Ready (GPS writing), and whether any camera has keep-alive intent. It asks
 * for nothing else — all decision logic lives here.
 */
import { hilog } from '@kit.PerformanceAnalysisKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { window } from '@kit.ArkUI';

const TAG = 'HarmoNiLink-BackgroundTaskKeeper';

export class BackgroundTaskKeeper {
  private getContext: () => common.UIAbilityContext | null;
  private getReadyCount: () => number;
  private getKeepAliveIntent: () => boolean;

  // Background task state — one ContinuousTask per app.
  private backgroundTaskStarted: boolean = false;
  // Generation guard for the async start()/sync stop() race: stop() bumps this
  // so an in-flight start() (getWantAgent/startBackgroundRunning are awaited)
  // can detect it landed after a stop request and immediately undo itself.
  private bgGeneration: number = 0;
  // Set when the system cancels OR suspends our ContinuousTask, or when a
  // warm return-to-foreground finds it gone without our own stop() (frozen
  // process → callbacks may never run). Latches the interrupt event so
  // inferSilentRevocation() won't re-infer it every foreground return; cleared
  // when a camera reaches Ready again (link restored → "现已恢复").
  private bgTaskCancelled: boolean = false;
  // Background modes currently held by the running ContinuousTask (string[] —
  // the single-value BackgroundMode overload accepts ONE mode only, and the
  // old `BLUETOOTH_INTERACTION | LOCATION` = 7 is not a valid enum value).
  private bgModes: string[] = [];
  // bgGeneration value at the last USER-driven stop (toggle off / no intent).
  // Distinguishes "task absent because we stopped it" from "task absent
  // because the system silently revoked it" in inferSilentRevocation().
  private userStopGeneration: number = -1;
  // Guards startBackgroundTask() against concurrent async double-fire:
  // startGpsLoop() and reconcileBackgroundTask() can both call it in the same
  // tick; backgroundTaskStarted only flips true after getWantAgent+start
  // resolve, so without this gate both pass the guard and one hits 9800005.
  private bgStartInFlight: boolean = false;
  // Set whenever bgTaskCancelled is latched (any of the three paths); consumed
  // by the delayed foreground prompt — one dialog per interruption event.
  private pendingInterruptNotice: boolean = false;
  private interruptNoticeTimer: number = -1;

  constructor(getContext: () => common.UIAbilityContext | null,
    getReadyCount: () => number,
    getKeepAliveIntent: () => boolean) {
    this.getContext = getContext;
    this.getReadyCount = getReadyCount;
    this.getKeepAliveIntent = getKeepAliveIntent;
  }

  /** Register the ContinuousTask cancel/suspend listeners (once, at startup).
   * On cancel, the system silently revokes the task and the notification; we
   * must reset backgroundTaskStarted so a warm return-to-foreground re-applies
   * it, and set bgTaskCancelled to latch the interrupt event (drives the
   * interrupt notice). No re-apply here — the cancel callback window may
   * freeze the process, and the next reconcile / onAppForeground re-applies
   * naturally. */
  registerListeners(): void {
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
          hilog.warn(0x0001, TAG, `[BG] ContinuousTask cancelled — reason=${info.reason} id=${info.id}`);
          this.backgroundTaskStarted = false;
          this.bgModes = [];
          this.bgTaskCancelled = true;
          this.pendingInterruptNotice = true;
        });
    } catch (e) {
      hilog.warn(0x0001, TAG, `[BG] continuousTaskCancel on() fail: ${JSON.stringify(e)}`);
    }
    try {
      backgroundTaskManager.on('continuousTaskSuspend',
        (info: backgroundTaskManager.ContinuousTaskSuspendInfo): void => {
          // Suspend ≠ cancel for the SYSTEM (task paused, revivable on
          // foreground), but it IS equivalent for the USER: a suspended task
          // means the process gets frozen in the background — the reconnect
          // dies and health sampling goes dark. Per official docs (API 20+),
          // registering this listener makes suspend (not cancel) the system's
          // FIRST response to "task not doing its business", so without this
          // flag the interruption was never surfaced. Mark it; Ready clears.
          hilog.warn(0x0001, TAG, `[BG] ContinuousTask suspended — reason=${info.suspendReason}`);
          if (!info.suspendState) {
            // System re-activated the task (auto on foreground return): it is
            // running again with modes we didn't pick. Mark started with an
            // empty mode cache so the next reconcile() aligns modes via
            // updateBackgroundRunning() instead of a duplicate start.
            this.backgroundTaskStarted = true;
            this.bgModes = [];
            return;
          }
          this.backgroundTaskStarted = false;
          this.bgTaskCancelled = true;
          this.pendingInterruptNotice = true;
        });
    } catch (e) {
      hilog.warn(0x0001, TAG, `[BG] continuousTaskSuspend on() fail: ${JSON.stringify(e)}`);
    }
  }

  /** Start/stop the ContinuousTask to match current connection intent:
   * keep it while any camera is Ready (GPS writing) OR has keep-alive intent
   * (reconnecting in the background); stop it only when neither holds. When it
   * is already running, the held MODES track the Ready set in place — a camera
   * going Ready adds location, all dropping reverts to bluetooth-only. */
  reconcile(): void {
    const need = this.getReadyCount() > 0 || this.getKeepAliveIntent();
    if (need) {
      if (this.backgroundTaskStarted) {
        const want = this.currentModes();
        if (!this.sameModes(want)) this.updateTask(want);
      } else {
        this.startTask();
      }
    } else {
      this.stop();
    }
  }

  private async startTask(): Promise<void> {
    if (this.backgroundTaskStarted || this.bgStartInFlight) return;
    const ctx = this.getContext();
    if (!ctx) return;
    this.bgStartInFlight = true; // concurrent callers must not double-fire
    const gen = this.bgGeneration; // this request's generation
    // Multi-mode MUST use the string[] overload: the single-value
    // BackgroundMode overload accepts ONE mode, and
    // `BLUETOOTH_INTERACTION | LOCATION` = 7 is not a valid enum value (the
    // enum skips 7). Legal multi-mode is a string[].
    const modes = this.currentModes();

    let wantAgentInfo: wantAgent.WantAgentInfo = {
      wants: [
        {
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }
      ],
      actionType: wantAgent.OperationType.START_ABILITY,
      requestCode: 0,
      wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
    };

    try {
      const agent: WantAgent = await wantAgent.getWantAgent(wantAgentInfo);
      if (gen !== this.bgGeneration) return; // a stop() raced in — abandon
      try {
        await backgroundTaskManager.startBackgroundRunning(ctx, modes, agent);
        if (gen !== this.bgGeneration) {
          // Start landed after a stop request — immediately undo it, else the
          // notification task hangs while every switch is off.
          hilog.info(0x0001, TAG, '[BG] ContinuousTask started after stop — undoing');
          try { backgroundTaskManager.stopBackgroundRunning(ctx); } catch (e) { /* best-effort */ }
          this.backgroundTaskStarted = false;
          return;
        }
        this.backgroundTaskStarted = true;
        this.bgModes = modes;
        this.userStopGeneration = -1; // fresh start — clear any stale user-stop mark
        hilog.info(0x0001, TAG, `[BG] ContinuousTask started (${modes.join('+')})`);
      } catch (err) {
        const be = err as BusinessError;
        if (be.code === 9800005) {
          // "Continuous task verification failed — already applied": the system
          // still holds our task (e.g. suspended-but-registered, auto-resumed
          // on foreground). Treat as running; empty mode cache makes the next
          // reconcile() align modes via updateBackgroundRunning.
          hilog.info(0x0001, TAG, '[BG] start hit 9800005 — task already registered, syncing state');
          this.backgroundTaskStarted = true;
          this.bgModes = [];
        } else {
          hilog.warn(0x0001, TAG,
            `[BG] startBackgroundRunning fail: ${be.code} ${be.message}`);
        }
      }
      if (gen !== this.bgGeneration && this.backgroundTaskStarted) {
        // A stop() raced in while we were starting — undo, same as above.
        try { backgroundTaskManager.stopBackgroundRunning(ctx); } catch (e) { /* best-effort */ }
        this.backgroundTaskStarted = false;
      }
    } catch (err) {
      hilog.warn(0x0001, TAG,
        `[BG] getWantAgent fail: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
    } finally {
      this.bgStartInFlight = false; // single cleanup point — early returns above can't strand the gate
    }
  }

  /** Dynamic single/multi-mode: while any camera is Ready (GPS writing) hold
   * bluetooth + location; during pure reconnect (no Ready session) hold only
   * bluetooth. Every held mode must have real business backing it — otherwise
   * the system may cancel the task as "unused" (SYSTEM_CANCEL_NOT_USE_LOCATION
   * when LOCATION is held but GPS isn't writing). */
  private currentModes(): string[] {
    return this.getReadyCount() > 0
      ? ['bluetoothInteraction', 'location']
      : ['bluetoothInteraction'];
  }

  private sameModes(modes: string[]): boolean {
    if (modes.length !== this.bgModes.length) return false;
    for (let i = 0; i < modes.length; i++) {
      if (modes[i] !== this.bgModes[i]) return false;
    }
    return true;
  }

  /** Switch the running ContinuousTask's background modes in place (add/remove
   * location as cameras enter/leave Ready). */
  private updateTask(modes: string[]): void {
    const ctx = this.getContext();
    if (!ctx) return;
    backgroundTaskManager.updateBackgroundRunning(ctx, modes).then(() => {
      this.bgModes = modes;
      hilog.info(0x0001, TAG, `[BG] ContinuousTask modes → ${modes.join('+')}`);
    }).catch((err: BusinessError) => {
      hilog.warn(0x0001, TAG,
        `[BG] updateBackgroundRunning fail: ${err.code} ${err.message}`);
    });
  }

  stop(): void {
    this.bgGeneration++; // invalidate any in-flight start()
    if (!this.backgroundTaskStarted) return;
    const ctx = this.getContext();
    if (!ctx) return;

    try {
      backgroundTaskManager.stopBackgroundRunning(ctx);
      this.backgroundTaskStarted = false;
      this.bgModes = [];
      this.userStopGeneration = this.bgGeneration; // we did this — not the system
      hilog.info(0x0001, TAG, '[BG] ContinuousTask stopped');
    } catch (err) {
      hilog.warn(0x0001, TAG,
        `[BG] stopBackgroundRunning error: ${(err as BusinessError).code} ${(err as BusinessError).message}`);
    }
  }

  // ==================== Interrupt notice (foreground dialog) ====================

  /** A camera reached Ready — the link is restored: clear the interrupt latch
   * so the NEXT revocation can re-notify, and settle any pending notice (if
   * the link came back while the user was watching, don't pop the dialog on
   * some much-later foreground return). */
  onReadyLinkRestored(): void {
    if (this.bgTaskCancelled) {
      this.bgTaskCancelled = false;
      hilog.info(0x0001, TAG, '[BG] camera Ready — cleared interrupt latch');
    }
    this.pendingInterruptNotice = false;
  }

  /** Foreground-return notice for a background interruption. Fires ~4s after
   * returning so the reconnect (which usually lands in 2–5s) settles first —
   * one dialog per interruption event, fixed copy that covers both outcomes
   * ("现已尝试恢复"). Skipped entirely if the user left before the delay. */
  scheduleInterruptNotice(isForeground: () => boolean): void {
    if (!this.pendingInterruptNotice) return;
    this.pendingInterruptNotice = false; // consume: never re-prompt this event
    if (this.interruptNoticeTimer !== -1) clearTimeout(this.interruptNoticeTimer);
    const ctx = this.getContext();
    this.interruptNoticeTimer = setTimeout(() => {
      this.interruptNoticeTimer = -1;
      if (!isForeground() || !ctx) return; // user already left again
      window.getLastWindow(ctx).then((win) => {
        win.getUIContext().getPromptAction().showDialog({
          title: '连接提醒',
          message: '因长时间未成功连接到设备，后台进程被系统中断。现已尝试恢复。',
          buttons: [{ text: '知道了', color: '#0A59F7' }]
        }).catch((e: BusinessError) => {
          hilog.warn(0x0001, TAG, `[BG] interrupt-notice dialog fail: ${e.message}`);
        });
      }).catch((e: BusinessError) => {
        hilog.warn(0x0001, TAG, `[BG] interrupt-notice getLastWindow fail: ${e.message}`);
      });
    }, 4000);
  }

  /** Fallback for revocations whose callbacks never ran: while frozen in the
   * background the process can't execute cancel/suspend handlers, and a
   * cold-ish thaw may deliver neither. On warm foreground, keep-alive intent +
   * no Ready session + task not running (and we didn't stop it ourselves —
   * userStopGeneration guards that path) means the system silently revoked it.
   * Mark bgTaskCancelled so the interrupt notice explains the gap. */
  inferSilentRevocation(): void {
    if (this.bgTaskCancelled || !this.getKeepAliveIntent()) return;
    if (this.getReadyCount() > 0) return;
    if (this.backgroundTaskStarted) return;
    if (this.bgStartInFlight) return; // a start is still in flight — not "gone"
    if (this.userStopGeneration === this.bgGeneration) return;
    hilog.warn(0x0001, TAG, '[BG] task gone without our stop() at foreground — inferring silent system revocation');
    this.bgTaskCancelled = true;
    this.pendingInterruptNotice = true;
  }
}
