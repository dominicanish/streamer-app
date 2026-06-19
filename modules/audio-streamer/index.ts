import { requireNativeModule, type EventSubscription } from 'expo-modules-core';

export type StatsEvent = {
  connected: boolean;
  device: string;
  bufferMs: number;
  underruns: number;
  bitrateKbps: number;
  clientPeak: number;   // 0..1 nivel reproducido en el teléfono
  serverPeak: number;   // 0..1 nivel en el PC
  mutedPc: boolean;
  flow: boolean;        // ¿el servidor está enviando (no silencio)?
};

export type LogEvent = { message: string; level: 'info' | 'ok' | 'warn' | 'err' };

const Native = requireNativeModule('AudioStreamer');

/** Conecta al servidor (p.ej. "ws://10.0.0.121:8080") con un jitter buffer de `bufferMs`. */
export function connect(url: string, bufferMs: number): void {
  Native.connect(url, bufferMs);
}

export function disconnect(): void {
  Native.disconnect();
}

export function setBufferMs(ms: number): void {
  Native.setBufferMs(ms);
}

export function addStatsListener(cb: (e: StatsEvent) => void): EventSubscription {
  return Native.addListener('onStats', cb);
}

export function addLogListener(cb: (e: LogEvent) => void): EventSubscription {
  return Native.addListener('onLog', cb);
}
