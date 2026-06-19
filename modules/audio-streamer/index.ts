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
  paused: boolean;      // ¿pausado por el usuario?
  npTitle: string;      // "now playing": título
  npArtist: string;     // artista (o vacío)
  npApp: string;        // app fuente (Chrome, Spotify…)
};

export type LogEvent = { message: string; level: 'info' | 'ok' | 'warn' | 'err' };

// El módulo nativo solo existe en un development/standalone build. En Expo Go (o
// web) no está, así que usamos un stub para poder previsualizar la UI sin firmar.
type NativeShape = {
  connect(url: string, bufferMs: number): void;
  disconnect(): void;
  setBufferMs(ms: number): void;
  pause(): void;
  resume(): void;
  addListener(event: string, cb: (e: any) => void): EventSubscription;
};

let Native: NativeShape;
export const isNativeAvailable = (() => {
  try {
    Native = requireNativeModule('AudioStreamer') as unknown as NativeShape;
    return true;
  } catch {
    const logCbs: ((e: LogEvent) => void)[] = [];
    Native = {
      connect: () => setTimeout(
        () => logCbs.forEach((cb) => cb({ message: 'Modo demo (UI): el audio solo funciona en el build instalado.', level: 'warn' })),
        50,
      ),
      disconnect: () => {},
      setBufferMs: () => {},
      pause: () => {},
      resume: () => {},
      addListener: (event, cb) => {
        if (event === 'onLog') logCbs.push(cb as any);
        return { remove() {} } as EventSubscription;
      },
    };
    return false;
  }
})();

/** Conecta al servidor (p.ej. "ws://10.0.0.121:8080") con un jitter buffer de `bufferMs`. */
export function connect(url: string, bufferMs: number): void { Native.connect(url, bufferMs); }
export function disconnect(): void { Native.disconnect(); }
export function setBufferMs(ms: number): void { Native.setBufferMs(ms); }

/** Pausa: silencia el teléfono y pausa la fuente real en el PC (SMTC). */
export function pause(): void { Native.pause(); }
export function resume(): void { Native.resume(); }

export function addStatsListener(cb: (e: StatsEvent) => void): EventSubscription {
  return Native.addListener('onStats', cb);
}
export function addLogListener(cb: (e: LogEvent) => void): EventSubscription {
  return Native.addListener('onLog', cb);
}
/** Carátula del "now playing" como data-URI (o '' para limpiar). */
export function addArtworkListener(cb: (dataUri: string) => void): EventSubscription {
  return Native.addListener('onArtwork', (e: { dataUri: string }) => cb(e?.dataUri ?? ''));
}
