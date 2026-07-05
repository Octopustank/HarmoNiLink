/**
 * Type declarations for the NAPI Blowfish module.
 * Import in ArkTS: import blowfish from 'libblowfish.so';
 */
declare namespace blowfish {
  /**
   * Encrypt a single 8-byte Blowfish block.
   * @param left - high 32 bits, big-endian (int32)
   * @param right - low 32 bits, big-endian (int32)
   * @returns [encrypted_hi, encrypted_lo] as int32 big-endian values
   */
  function encryptBlock(left: number, right: number): [number, number];
}

export default blowfish;
