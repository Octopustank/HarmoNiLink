/**
 * GeoPayloadGenerator.ets — Build 41-byte Nikon GEO payload from real GPS data.
 *
 * Based on nsg/android/.../GeoPayloadGenerator.kt and nsg/doc/nikon-z-gps.md §7
 *
 * [CHECKPOINT] Payload format (41 bytes, little-endian):
 *   0-1:   header 0x007F
 *   2:     lat direction ('N'/'S')
 *   3:     lat degrees
 *   4:     lat minutes
 *   5:     lat submin1 (hundredths of minute)
 *   6:     lat submin2 (hundredths of remainder)
 *   7:     lon direction ('E'/'W')
 *   8:     lon degrees
 *   9:     lon minutes
 *   10:    lon submin1
 *   11:    lon submin2
 *   12:    satellites (3-12)
 *   13:    altitude ref ('P'/'M')
 *   14-15: altitude (uint16 LE, meters)
 *   16-22: UTC time (year LE, month, day, hour, minute, second)
 *   23:    subseconds (0-99)
 *   24:    valid flag (0x01)
 *   25-30: "WGS-84" ASCII
 *   31-40: padding 0x00
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarmoNikon-GeoPayload';

const HEADER: number = 0x007F;

export interface GpsPosition {
  latitude: number;   // decimal degrees
  longitude: number;  // decimal degrees
  altitude: number;   // meters
  satellites: number; // 3-12
  timestamp: Date;    // UTC time
}

interface DirectionalCoordinate {
  direction: number; // 'N' or 'S' / 'E' or 'W' as ASCII byte
  degrees: number;
  minutes: number;
  submin1: number;
  submin2: number;
}

export class GeoPayloadGenerator {
  /**
   * Build 41-byte GEO payload from real GPS position.
   */
  static buildReal(pos: GpsPosition): Uint8Array {
    const latCoord = GeoPayloadGenerator.decimalToNikon(pos.latitude, 0x4E, 0x53); // 'N'=78, 'S'=83
    const lonCoord = GeoPayloadGenerator.decimalToNikon(pos.longitude, 0x45, 0x57); // 'E'=69, 'W'=87

    const buf = new ArrayBuffer(41);
    const dv = new DataView(buf);
    let off = 0;

    // Header
    dv.setUint16(off, HEADER, true);
    off += 2;

    // Latitude
    dv.setUint8(off++, latCoord.direction);
    dv.setUint8(off++, latCoord.degrees);
    dv.setUint8(off++, latCoord.minutes);
    dv.setUint8(off++, latCoord.submin1);
    dv.setUint8(off++, latCoord.submin2);

    // Longitude
    dv.setUint8(off++, lonCoord.direction);
    dv.setUint8(off++, lonCoord.degrees);
    dv.setUint8(off++, lonCoord.minutes);
    dv.setUint8(off++, lonCoord.submin1);
    dv.setUint8(off++, lonCoord.submin2);

    // Satellites
    dv.setUint8(off++, Math.max(3, Math.min(12, pos.satellites)));

    // Altitude
    dv.setUint8(off++, pos.altitude >= 0 ? 0x50 : 0x4D); // 'P' or 'M'
    dv.setUint16(off, Math.abs(pos.altitude) & 0xFFFF, true);
    off += 2;

    // UTC time
    const year = pos.timestamp.getUTCFullYear();
    dv.setUint16(off, year, true);
    off += 2;
    dv.setUint8(off++, pos.timestamp.getUTCMonth() + 1);
    dv.setUint8(off++, pos.timestamp.getUTCDate());
    dv.setUint8(off++, pos.timestamp.getUTCHours());
    dv.setUint8(off++, pos.timestamp.getUTCMinutes());
    dv.setUint8(off++, pos.timestamp.getUTCSeconds());

    // Subseconds (hundredths)
    const ms = pos.timestamp.getUTCMilliseconds();
    dv.setUint8(off++, Math.floor(ms / 10));

    // Valid flag
    dv.setUint8(off++, 0x01);

    // "WGS-84"
    const wgs84 = [0x57, 0x47, 0x53, 0x2D, 0x38, 0x34]; // 'W','G','S','-','8','4'
    for (let i = 0; i < 6; i++) {
      dv.setUint8(off++, wgs84[i]);
    }

    // Padding
    for (let i = 0; i < 10; i++) {
      dv.setUint8(off++, 0x00);
    }

    const payload = new Uint8Array(buf);
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] buildReal: lat=${pos.latitude.toFixed(6)} lon=${pos.longitude.toFixed(6)} alt=${pos.altitude}m sats=${pos.satellites} payloadLen=${payload.length}`);

    return payload;
  }

  /**
   * Build a fake GEO payload for testing without real GPS.
   */
  static buildFake(): Uint8Array {
    const pos: GpsPosition = {
      latitude: Math.random() * 180 - 90,
      longitude: Math.random() * 360 - 180,
      altitude: Math.floor(Math.random() * 5000),
      satellites: Math.floor(Math.random() * 10) + 3,
      timestamp: new Date()
    };
    return GeoPayloadGenerator.buildReal(pos);
  }

  /**
   * Convert decimal degrees to Nikon's degrees/minutes/submin format.
   */
  private static decimalToNikon(
    decimal: number,
    positiveDirection: number,
    negativeDirection: number
  ): DirectionalCoordinate {
    const direction = decimal < 0 ? negativeDirection : positiveDirection;
    const abs = Math.abs(decimal);
    const degrees = Math.floor(abs);
    const minutesFull = (abs - degrees) * 60.0;
    const minutes = Math.floor(minutesFull);
    const submin1Full = (minutesFull - minutes) * 100.0;
    const submin1 = Math.floor(submin1Full);
    const submin2Full = (submin1Full - submin1) * 100.0;
    const submin2 = Math.floor(submin2Full);

    return { direction, degrees, minutes, submin1, submin2 };
  }
}
