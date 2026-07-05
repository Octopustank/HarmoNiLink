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
 *   byte 7:    daylight saving offset (0)
 *   byte 8:    timezone offset hours (8 = UTC+8)
 *   byte 9:    timezone offset minutes (0)
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
    dv.setUint8(7, 0);  // DST
    dv.setUint8(8, 8);  // UTC+8
    dv.setUint8(9, 0);
    return new Uint8Array(buf);
  }
}
