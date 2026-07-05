/**
 * PairingMessage.ets — 17-byte Nikon pairing message encode/decode
 *
 * Wire format (little-endian):
 *   byte 0:        stage (uint8)
 *   bytes 1-8:     timestamp (uint64 LE)
 *   bytes 9-12:    device (uint32 LE)
 *   bytes 13-16:   nonce (uint32 LE)
 *
 * Based on nsg/android/.../PairingMessage.kt
 */
export class PairingMessage {
  readonly stage: number;
  readonly timestamp: bigint; // uint64 — MUST be bigint to avoid precision loss (JS number is only 53-bit safe)
  readonly device: number;    // uint32
  readonly nonce: number;     // uint32

  constructor(stage: number, timestamp: bigint, device: number, nonce: number) {
    this.stage = stage & 0xFF;
    this.timestamp = timestamp;
    this.device = device & 0xFFFFFFFF;
    this.nonce = nonce & 0xFFFFFFFF;
  }

  encode(): Uint8Array {
    const buf = new ArrayBuffer(17);
    const dv = new DataView(buf);
    dv.setUint8(0, this.stage);
    dv.setBigUint64(1, this.timestamp, true);
    dv.setUint32(9, this.device, true);
    dv.setUint32(13, this.nonce, true);
    return new Uint8Array(buf);
  }

  static decode(data: Uint8Array): PairingMessage {
    if (data.length !== 17) {
      throw new Error(`PairingMessage: expected 17 bytes, got ${data.length}`);
    }
    const dv = new DataView(data.buffer, data.byteOffset, 17);
    const stage = dv.getUint8(0);
    const timestamp = dv.getBigUint64(1, true); // keep as bigint — DO NOT convert to Number!
    const device = dv.getUint32(9, true);
    const nonce = dv.getUint32(13, true);
    return new PairingMessage(stage, timestamp, device, nonce);
  }

  toString(): string {
    return `PairingMessage(stage=${this.stage} ts=0x${this.timestamp.toString(16)} dev=0x${this.device.toString(16)} nonce=0x${this.nonce.toString(16)})`;
  }
}
