/**
 * BleEvent.ets — Event types for BLE communication
 * Based on nsg/android/.../BleEvent.kt
 */

export class BleEvent { }

export class BleConnected extends BleEvent {
  readonly _tag: string = 'Connected';
}
export class BleDisconnected extends BleEvent {
  readonly _tag: string = 'Disconnected';
}
export class BleServicesDiscovered extends BleEvent {
  readonly _tag: string = 'ServicesDiscovered';
}
export class BleMtuChanged extends BleEvent {
  readonly mtu: number;
  constructor(mtu: number) { super(); this.mtu = mtu; }
}
export class BlePairIndication extends BleEvent {
  readonly data: Uint8Array;
  constructor(data: Uint8Array) { super(); this.data = data; }
}
export class BleNot1Notification extends BleEvent {
  readonly data: Uint8Array;
  constructor(data: Uint8Array) { super(); this.data = data; }
}
export class BleWriteDone extends BleEvent {
  readonly uuid: string;
  readonly status: number;
  constructor(uuid: string, status: number) { super(); this.uuid = uuid; this.status = status; }
}
export class BleError extends BleEvent {
  readonly message: string;
  constructor(message: string) { super(); this.message = message; }
}
