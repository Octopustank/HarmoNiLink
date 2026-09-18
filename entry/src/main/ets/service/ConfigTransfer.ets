/**
 * ConfigTransfer.ets — 关于页 配置导出/导入
 *
 * Why: after a reinstall / device migration the OS-level BLE bond and the
 * camera-side pair record still exist — only the APP-side record (paired
 * cameras + the controller name the camera knows us by) is gone. Restoring
 * that record re-enables reconnect without re-pairing.
 *
 * Export: DocumentViewPicker save → fileIo write of a MINIMAL snapshot
 * {app, schema, exportedAt, controllerName, cameras[{name,address,
 * addressType,device,nonce}]}. Per-camera controllerName is omitted — the
 * top-level value is canonical (import fills it in).
 *
 * Import overwrite semantics (user-confirmed before applying): replaces the
 * controller name + paired camera list and clears ALL connection-health
 * (SLA) records.
 *
 * Security — the picked file is UNTRUSTED input:
 *  - size cap BEFORE parse (256 KB), JSON.parse in try/catch
 *  - magic + schema version gate
 *  - strict whitelist per field: exact key sets (nothing extra smuggled),
 *    types, length caps, MAC regex, uint32 ranges, no control characters,
 *    no duplicate names, camera-count cap
 *  - ANY violation rejects the WHOLE file — no partial application, no
 *    coercion, no defaults. Error messages are user-readable reasons.
 */
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { buffer } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { PairedCamera } from '../ble/protocol/NikonPairingEngine';

const TAG = 'HarmoNiLink-ConfigTransfer';

const MAGIC = 'HarmoNiLink';
const SCHEMA_VERSION = 1;
const MAX_FILE_BYTES = 256 * 1024;
const MAX_CAMERAS = 20;
const MAX_NAME_LEN = 64;
// Must match SUFFIX_CHARS in PreferencesRepository (no 0/O/1/I).
const CONTROLLER_NAME_RE = /^HarmoNiLink-[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]{4}$/;
const MAC_RE = /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/;
// eslint-disable-next-line no-control-regex
const CONTROL_CHAR_RE = /[\u0000-\u001F\u007F]/;

/** Validated import payload. */
export interface ConfigSnapshot {
  controllerName: string;
  cameras: PairedCamera[];
}

/** Raw parsed shapes — every field optional, all guarded by typeof. */
interface RawCamera {
  name?: string;
  address?: string;
  addressType?: number;
  device?: number;
  nonce?: number;
}

interface RawConfig {
  app?: string;
  schema?: number;
  exportedAt?: number;
  controllerName?: string;
  cameras?: RawCamera[];
}

const TOP_LEVEL_KEYS = 'app,cameras,controllerName,exportedAt,schema';
const CAMERA_KEYS = 'address,addressType,device,name,nonce';
const ERR_FILE_TOO_LARGE = '文件过大，不是有效的配置备份';

/** Serialized shapes (ArKTS requires explicit types for object literals). */
interface ExportCamera {
  name: string;
  address: string;
  addressType: number;
  device: number;
  nonce: number;
}
interface ExportSnapshot {
  app: string;
  schema: number;
  exportedAt: number;
  controllerName: string;
  cameras: ExportCamera[];
}

export class ConfigTransfer {
  /** Serialize the current state and let the user save it. Returns the
   *  chosen file name, or '' when the user cancelled. Throws Error with a
   *  user-readable message on real failures. */
  static async exportConfig(
    ctx: common.UIAbilityContext,
    controllerName: string,
    cameras: PairedCamera[]
  ): Promise<string> {
    const now = new Date();
    const stamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}`;
    const fileName = `HarmoNiLink-config-${stamp}.json`;
    const snapshot: ExportSnapshot = {
      app: MAGIC,
      schema: SCHEMA_VERSION,
      exportedAt: Date.now(),
      controllerName: controllerName,
      cameras: cameras.map((c: PairedCamera): ExportCamera => {
        const row: ExportCamera = {
          name: c.name,
          address: c.address,
          addressType: c.addressType,
          device: c.device,
          nonce: c.nonce
        };
        return row;
      })
    };

    let uri = '';
    try {
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [fileName];
      options.fileSuffixChoices = ['.json'];
      const dp = new picker.DocumentViewPicker(ctx);
      const result: Array<string> = await dp.save(options);
      if (!result || result.length === 0) return ''; // user cancelled
      uri = result[0];
    } catch (err) {
      hilog.warn(0x0001, TAG, `export picker fail: ${JSON.stringify(err)}`);
      throw new Error('无法打开文件保存窗口');
    }

    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, JSON.stringify(snapshot, null, 2));
      } finally {
        fileIo.closeSync(file);
      }
    } catch (err) {
      hilog.warn(0x0001, TAG, `export write fail: ${JSON.stringify(err)}`);
      throw new Error('写入文件失败，请重试');
    }
    hilog.info(0x0001, TAG, `exported ${snapshot.cameras.length} camera(s)`);
    return fileName;
  }

  /** Let the user pick a config file and validate it strictly. Resolves null
   *  when the user cancelled. Rejects Error(user-readable Chinese) when the
   *  file is invalid or unreadable. */
  static async importConfig(ctx: common.UIAbilityContext): Promise<ConfigSnapshot | null> {
    let uri = '';
    try {
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['配置文件|.json'];
      const dp = new picker.DocumentViewPicker(ctx);
      const result: Array<string> = await dp.select(options);
      if (!result || result.length === 0) return null; // user cancelled
      uri = result[0];
    } catch (err) {
      hilog.warn(0x0001, TAG, `import picker fail: ${JSON.stringify(err)}`);
      throw new Error('无法打开文件选择窗口');
    }

    let text = '';
    try {
      const file = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      try {
        const stat = fileIo.statSync(file.fd);
        if (stat.size > MAX_FILE_BYTES) {
          throw new Error(ERR_FILE_TOO_LARGE);
        }
        const buf = new ArrayBuffer(stat.size);
        const readLen = fileIo.readSync(file.fd, buf);
        text = buffer.from(buf, 0, readLen).toString();
      } finally {
        fileIo.closeSync(file);
      }
    } catch (err) {
      if (err instanceof Error && err.message === ERR_FILE_TOO_LARGE) {
        throw new Error(ERR_FILE_TOO_LARGE);
      }
      hilog.warn(0x0001, TAG, `import read fail: ${JSON.stringify(err)}`);
      throw new Error('无法读取所选文件');
    }
    return ConfigTransfer.validate(text);
  }

  /** Strict whitelist validation — throws Error(user-readable) on the FIRST
   *  violation; a rejected file is never partially applied. */
  private static validate(text: string): ConfigSnapshot {
    let raw: RawConfig;
    try {
      raw = JSON.parse(text) as RawConfig;
    } catch (e) {
      throw new Error('文件不是有效的 JSON 文本');
    }
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      throw new Error('文件内容不是配置对象');
    }
    // Exact key sets — nothing extra may ride along.
    if (Object.keys(raw).sort().join(',') !== TOP_LEVEL_KEYS) {
      throw new Error('配置结构不匹配（字段缺失或多余）');
    }
    if (raw.app !== MAGIC) {
      throw new Error('不是 HarmoNiLink 的配置文件');
    }
    if (raw.schema !== SCHEMA_VERSION) {
      throw new Error('配置版本不受支持，请升级应用后重试');
    }
    if (typeof raw.exportedAt !== 'number' || !Number.isFinite(raw.exportedAt)) {
      throw new Error('配置时间戳无效');
    }
    const controllerName = raw.controllerName;
    if (typeof controllerName !== 'string' || !CONTROLLER_NAME_RE.test(controllerName)) {
      throw new Error('设备名格式无效');
    }
    if (!Array.isArray(raw.cameras)) {
      throw new Error('相机列表无效');
    }
    if (raw.cameras.length > MAX_CAMERAS) {
      throw new Error(`相机数量超出上限（${MAX_CAMERAS} 台）`);
    }
    const cameras: PairedCamera[] = [];
    const seen = new Set<string>();
    for (let i = 0; i < raw.cameras.length; i++) {
      const c = raw.cameras[i];
      const label = `第 ${i + 1} 台相机`;
      if (!c || typeof c !== 'object' || Array.isArray(c)) {
        throw new Error(`${label}记录无效`);
      }
      if (Object.keys(c).sort().join(',') !== CAMERA_KEYS) {
        throw new Error(`${label}字段不匹配`);
      }
      const name = c.name;
      if (typeof name !== 'string' || name.length === 0 || name.length > MAX_NAME_LEN
        || CONTROL_CHAR_RE.test(name)) {
        throw new Error(`${label}名称无效`);
      }
      if (seen.has(name)) {
        throw new Error('相机名称重复');
      }
      seen.add(name);
      const address = c.address;
      if (typeof address !== 'string' || !MAC_RE.test(address)) {
        throw new Error(`${label}地址无效`);
      }
      const addressType = c.addressType;
      if (typeof addressType !== 'number' || !Number.isInteger(addressType)
        || addressType < 0 || addressType > 255) {
        throw new Error(`${label}地址类型无效`);
      }
      const device = c.device;
      if (typeof device !== 'number' || !Number.isInteger(device)
        || device < 0 || device > 0xFFFFFFFF) {
        throw new Error(`${label}设备号无效`);
      }
      const nonce = c.nonce;
      if (typeof nonce !== 'number' || !Number.isInteger(nonce)
        || nonce < 0 || nonce > 0xFFFFFFFF) {
        throw new Error(`${label}握手数据无效`);
      }
      cameras.push(new PairedCamera(name, address, addressType, device, nonce, controllerName, false));
    }
    return { controllerName: controllerName, cameras: cameras };
  }
}
