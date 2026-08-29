/**
 * ConnectionTypes.ets — shared connection-state vocabulary
 *
 * Extracted from CameraService so CameraSession / pages can import the TYPES
 * without importing the Hub class (which imports CameraSession — a module
 * cycle). The Hub, sessions, and UI pages all speak this one enum/event shape.
 */

/** Lifecycle of one camera's link, broadcast per-camera by the Hub. */
export enum ConnectionState {
  Idle = 'Idle',
  Scanning = 'Scanning',
  Connecting = 'Connecting',
  Discovering = 'Discovering',
  Pairing = 'Pairing',
  Bonding = 'Bonding',
  Ready = 'Ready',
  Error = 'Error',
}

/** A per-camera state change, broadcast to all listeners. */
export interface CameraStateEvent {
  /** '' for global (pairing-scan / ownership) events; otherwise the camera name. */
  cameraName: string;
  state: ConnectionState;
  message: string;
}

export type StateListener = (event: CameraStateEvent) => void;

/** Which tab holds the Hub's pairing-only radio mutex. */
export type OperationOwner = 'pairing' | 'connection' | 'none';
