/**
 * TimePayloadGenerator.ets — 10-byte TIME payload for Nikon camera
 *
 * Wire format (little-endian):
 *   bytes 0-1: year (uint16 LE)
 *   byte 2:    month (1-12)
 *   byte 3:    day (1-31)
 *   byte 4:    hour (0-23)
 *   byte 5:    minute (0-59)
 *   byte 6:    second (0-59)
 *   byte 7:    daylight saving offset (0 — getTimezoneOffset() already includes DST)
 *   byte 8:    timezone offset hours (signed, from system timezone; +8 = UTC+8)
 *   byte 9:    timezone offset minutes (0-59, from system timezone)
 *
 * Based on nsg/kotlin-poc/.../TimePayloadGenerator.kt
 */
export class TimePayloadGenerator {
  static build(): Uint8Array {
    const now = new Date();
    const buf = new ArrayBuffer(10);
    const dv = new DataView(buf);
    dv.setUint16(0, now.getUTCFullYear(), true);
    dv.setUint8(2, now.getUTCMonth() + 1);
    dv.setUint8(3, now.getUTCDate());
    dv.setUint8(4, now.getUTCHours());
    dv.setUint8(5, now.getUTCMinutes());
    dv.setUint8(6, now.getUTCSeconds());
    dv.setUint8(7, 0);  // DST — already included in getTimezoneOffset(), no separate offset
    // Timezone offset from system — positive = east of UTC (e.g. +8 for China).
    // Date.getTimezoneOffset() returns (UTC - local) in minutes, so negate it.
    const offsetMinutes = -new Date().getTimezoneOffset();
    const offsetHours = Math.floor(offsetMinutes / 60);
    const offsetRemainder = Math.abs(offsetMinutes % 60);
    dv.setInt8(8, offsetHours);  // signed — western hemisphere offsets stay negative
    dv.setUint8(9, offsetRemainder);
    return new Uint8Array(buf);
  }
}
