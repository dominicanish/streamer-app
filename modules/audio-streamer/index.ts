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

// El módulo nativo solo existe en un development/standalone build. En Expo Go (o
// web) no está, así que usamos un stub para poder previsualizar la UI sin firmar.
type NativeShape = {
  connect(url: string, bufferMs: number): void;
  disconnect(): void;
  setBufferMs(ms: number): void;
  addListener(event: string, cb: (e: any) => void): EventSubscription;
};

let Native: NativeShape;
export const isNativeAvailable = (() => {
  try {
    Native = requireNativeModule('AudioStreamer') as unknown as NativeShape;
    return true;
  } catch {
    // Stub para Expo Go / web: no-ops + avisa por el log que es modo demo.
    const logCbs: ((e: LogEvent) => void)[] = [];
    Native = {
      connect: () => setTimeout(
        () => logCbs.forEach((cb) => cb({ message: 'Modo demo (UI): el audio solo funciona en el build instalado.', level: 'warn' })),
        50,
      ),
      disconnect: () => {},
      setBufferMs: () => {},
      addListener: (event, cb) => {
        if (event === 'onLog') logCbs.push(cb as any);
        return { remove() {} } as EventSubscription;
      },
    };
    return false;
  }
})();

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
