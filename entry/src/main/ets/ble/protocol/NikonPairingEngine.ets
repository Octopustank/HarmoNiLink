/**
 * NikonPairingEngine.ets — Drives the 4-stage Nikon smart-device pairing handshake.
 *
 * [CHECKPOINT] Test vectors (from NikonPairingEngineTest.kt):
 *   stage1: ts=0x677da144ec13e1db, dev=0x3c3ae501, nonce=0x3fdaa451
 *   stage2: ts=0xb9943d5e8026fa29, dev=0xa8b3f2e4, nonce=0x16d56a13
 *   stage3: ts=same, dev=0x79f1ad53, nonce=0x23838a35
 *   stage3 bytes: 03 db e1 13 ec 44 a1 7d 67 53 ad f1 79 35 8a 83 23
 *
 * Based on nsg/android/.../NikonPairingEngine.kt
 */
import { PairingMessage } from './PairingMessage';
import { BlowfishHasher } from './BlowfishHasher';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'HarmoNikon-PairingEngine';

/**
 * Persisted camera data for reconnection.
 */
export class PairedCamera {
  readonly name: string;
  readonly address: string;
  readonly addressType: number;
  readonly device: number;  // uint32
  readonly nonce: number;   // uint32
  readonly controllerName: string;

  constructor(
    name: string, address: string, addressType: number,
    device: number, nonce: number, controllerName: string
  ) {
    this.name = name;
    this.address = address;
    this.addressType = addressType;
    this.device = device & 0xFFFFFFFF;
    this.nonce = nonce & 0xFFFFFFFF;
    this.controllerName = controllerName;
  }
}

/**
 * 8 salt values for the Blowfish challenge/response.
 * Each salt is two 32-bit words.
 */
const SALTS: number[][] = [
  [0x704066e4, 0x0433d552],
  [0xed4b8fac, 0x15f7e47b],
  [0x24471f11, 0x8b5ea1fc],
  [0x05960c31, 0x2b8c7f41],
  [0xfda588c1, 0xeba8b1f3],
  [0x99166056, 0x1bd3d550],
  [0xcd32687f, 0xa9e28a30],
  [0x2a8fe834, 0xdec7ebf4]
];

export class NikonPairingEngine {
  private hasher: BlowfishHasher;

  constructor() {
    this.hasher = new BlowfishHasher();
  }

  /**
   * Build stage 1. If saved is provided, its device/nonce are reused.
   * Device LSB must be 0x01 (on little-endian wire).
   */
  createStage1(saved: PairedCamera | null): PairingMessage {
    const timestamp = this.randomLong();
    let device: number;
    let nonce: number;

    if (saved) {
      device = saved.device;
      nonce = saved.nonce;
      hilog.info(0x0001, TAG, `[CHECKPOINT] createStage1: REUSE dev=0x${device.toString(16)} nonce=0x${nonce.toString(16)}`);
    } else {
      device = this.generateDeviceId();
      nonce = this.generateNonce();
      hilog.info(0x0001, TAG, `[CHECKPOINT] createStage1: NEW dev=0x${device.toString(16)} nonce=0x${nonce.toString(16)}`);
    }

    const msg = new PairingMessage(0x01, timestamp, device, nonce);
    hilog.info(0x0001, TAG, `[CHECKPOINT] createStage1: ${msg.toString()}`);
    return msg;
  }

  /**
   * Verify stage 2 challenge, find matching salt, build stage 3 response.
   * Returns null if no salt matches.
   */
  verifyStage2AndBuildStage3(stage1: PairingMessage, stage2: PairingMessage): PairingMessage | null {
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] verifyStage2: ts1=0x${stage1.timestamp.toString(16)} ts2=0x${stage2.timestamp.toString(16)}`);

    const saltIndex = this.findSalt(stage1, stage2);
    if (saltIndex === null) {
      hilog.error(0x0001, TAG, '[CHECKPOINT] verifyStage2: NO SALT MATCH — handshake FAILED');
      return null;
    }

    hilog.info(0x0001, TAG, `[CHECKPOINT] verifyStage2: matched SALT[${saltIndex}]`);

    const ts1 = this.timestampHalvesBe(stage1.timestamp);
    const ourLo = ts1[0];
    const ourHi = ts1[1];
    const ts2 = this.timestampHalvesBe(stage2.timestamp);
    const camLo = ts2[0];
    const camHi = ts2[1];

    // Stage 3 uses our timestamp first, then camera timestamp (opposite of stage 2)
    const blocks = [
      SALTS[saltIndex][0], SALTS[saltIndex][1],
      ourLo, ourHi,
      camLo, camHi
    ];

    const hashResult = this.hasher.hash(blocks);
    const r0 = hashResult[0];
    const r1 = hashResult[1];

    // Convert hash result from big-endian to little-endian for wire
    const deviceLe = this.reverseBytesU32(r0);
    const nonceLe = this.reverseBytesU32(r1);

    const stage3 = new PairingMessage(0x03, stage1.timestamp, deviceLe, nonceLe);
    hilog.info(0x0001, TAG,
      `[CHECKPOINT] verifyStage2AndBuildStage3: dev=0x${stage3.device.toString(16)} nonce=0x${stage3.nonce.toString(16)}`);

    return stage3;
  }

  /**
   * Extract 8-byte ASCII serial number from stage 4 message.
   */
  extractSerial(stage4: PairingMessage): string {
    const bytes = stage4.encode();
    const serialBytes = bytes.slice(9, 17);
    // Decode as ASCII
    let serial = '';
    for (let i = 0; i < serialBytes.length; i++) {
      if (serialBytes[i] === 0) break;
      serial += String.fromCharCode(serialBytes[i]);
    }
    hilog.info(0x0001, TAG, `[CHECKPOINT] extractSerial: '${serial}'`);
    return serial;
  }

  // ==================== Private helpers ====================

  private randomLong(): bigint {
    const hi = BigInt(Math.floor(Math.random() * 0x100000000));
    const lo = BigInt(Math.floor(Math.random() * 0x100000000));
    return (hi << 32n) | lo;
  }

  private generateDeviceId(): number {
    // First byte on wire must be 0x01 → LSB must be 0x01 (little-endian uint32)
    const rnd = Math.floor(Math.random() * 0x100000000);
    return (rnd & 0xFFFFFF00) | 0x01;
  }

  private generateNonce(): number {
    return Math.floor(Math.random() * 0x100000000);
  }

  /**
   * Find which salt matches the camera's stage 2 challenge.
   * For each salt i:
   *   hash(salt[i] || camTsHi || camTsLo || ourTsHi || ourTsLo)
   *   if result == (camDevice_be, camNonce_be) → matched
   */
  private findSalt(stage1: PairingMessage, stage2: PairingMessage): number | null {
    const ts2 = this.timestampHalvesBe(stage2.timestamp);
    const camLo = ts2[0];
    const camHi = ts2[1];
    const ts1 = this.timestampHalvesBe(stage1.timestamp);
    const ourLo = ts1[0];
    const ourHi = ts1[1];
    const camDeviceBe = this.reverseBytesU32(stage2.device);
    const camNonceBe = this.reverseBytesU32(stage2.nonce);

    hilog.info(0x0001, TAG,
      `[SALT] inputs: camLo=0x${(camLo>>>0).toString(16)} camHi=0x${(camHi>>>0).toString(16)}` +
      ` ourLo=0x${(ourLo>>>0).toString(16)} ourHi=0x${(ourHi>>>0).toString(16)}` +
      ` stage2.device=0x${((stage2.device as number)>>>0).toString(16)} stage2.nonce=0x${((stage2.nonce as number)>>>0).toString(16)}`);

    for (let i = 0; i < SALTS.length; i++) {
      const blocks = [
        SALTS[i][0], SALTS[i][1],
        camLo, camHi,
        ourLo, ourHi
      ];
      const hashRes = this.hasher.hash(blocks);
      const h0 = hashRes[0];
      const h1 = hashRes[1];

      hilog.info(0x0001, TAG,
        `[SALT] [${i}] hash=(${h0}, ${h1}) 0x${(h0>>>0).toString(16)},0x${(h1>>>0).toString(16)}` +
        ` exp=(${camDeviceBe}, ${camNonceBe}) 0x${(camDeviceBe>>>0).toString(16)},0x${(camNonceBe>>>0).toString(16)}` +
        ` ${h0===camDeviceBe&&h1===camNonceBe?'MATCH':'x'}`);

      if (h0 === camDeviceBe && h1 === camNonceBe) {
        return i;
      }
    }
    return null;
  }

  /**
   * Split a uint64 timestamp into two big-endian uint32 halves.
   * Step 1: extract LE lo, LE hi from the LE uint64
   * Step 2: reverse bytes to get BE values
   */
  private timestampHalvesBe(timestamp: bigint): [number, number] {
    const lo = Number(timestamp & 0xFFFFFFFFn);
    const hi = Number((timestamp >> 32n) & 0xFFFFFFFFn);
    return [this.reverseBytesU32(lo), this.reverseBytesU32(hi)];
  }

  /**
   * Reverse bytes of a uint32 (e.g., 0x12345678 → 0x78563412).
   * This is the big-endian ↔ little-endian conversion used by the protocol.
   */
  private reverseBytesU32(value: number): number {
    value = value >>> 0; // ensure unsigned
    return (
      ((value & 0x000000FF) << 24) |
      ((value & 0x0000FF00) << 8) |
      ((value & 0x00FF0000) >>> 8) |
      ((value & 0xFF000000) >>> 24)
    ) >>> 0;
  }
}
