# PC Speaker — cliente iOS nativo

App nativa (Expo + módulo Swift) que recibe el audio de tu PC por WebSocket y lo
reproduce con **baja latencia** y **audio en segundo plano / pantalla bloqueada**
(lo que la web no podía). Usa **tu mismo servidor Node** sin cambios.

## Arquitectura

```
Servidor Node (WASAPI loopback → PCM Int16 por WebSocket)
        │
        ▼   ws://<ip-del-PC>:8080
┌──────────────────────────────────────────────┐
│  Módulo Swift (modules/audio-streamer)        │
│   URLSessionWebSocketTask → ring buffer →     │
│   AVAudioSourceNode → AVAudioEngine            │
│   AVAudioSession(.playback) = background real │
└──────────────────────────────────────────────┘
        │  eventos onStats / onLog
        ▼
   UI React Native (App.tsx)
```

- **`modules/audio-streamer/ios/AudioStreamerModule.swift`** — todo el audio + red.
- **`App.tsx`** — la interfaz (oscura, VU, stats, logs, stepper de latencia).
- **`app.json`** — `UIBackgroundModes: audio`, permiso de red local, ATS para `ws://`.

## Requisitos

- Cuenta **Expo** (gratis): https://expo.dev
- **EAS CLI**: `npm i -g eas-cli`
- **Apple ID** (ver sección de firma abajo).

## Build en la nube (sin Mac)

```bash
cd streamer-app
eas login                 # tu cuenta Expo
eas build:configure       # vincula el proyecto (crea projectId)

# Build standalone para usar (JS empaquetado, no necesita Metro):
eas build --profile preview --platform ios
```

EAS compila en sus Macs. Al final te da un enlace/QR para instalar el `.ipa`.

> **Primer build = prueba de compilación del Swift.** Lo escribí sin Mac, así que es
> probable que el primer intento tire errores de compilación. **Pásame el log de
> EAS** y los corrijo. Iteramos hasta que compile.

### Iterar rápido (opcional)

Para cambios de UI sin recompilar nativo:
```bash
eas build --profile development --platform ios   # build con dev client (una vez)
npx expo start --dev-client                       # Metro en el PC
```
Abres la app en el iPhone (misma WiFi) y los cambios de `App.tsx` recargan al vuelo.
Cambios en el **Swift** sí requieren un nuevo `eas build`.

## Firma (la decisión de coste)

iOS exige firmar. Dos caminos:

- **Apple Developer ($99/año):** `eas build` lo hace todo solo (certificados,
  perfiles, instalación interna o TestFlight). Sin fricción. **Recomendado.**
- **Gratis:** EAS no firma con cuenta gratis. La ruta es: generar un `.ipa` sin
  firmar con CI macOS (GitHub Actions / Codemagic) y firmarlo con **Sideloadly**
  usando tu Apple ID gratis (caduca cada 7 días). Más pasos; se puede montar.

## Usar la app

1. En el PC: `cd streamer && npm start` (servidor corriendo).
2. iPhone en la **misma WiFi**.
3. Abre la app, escribe `ws://<ip-del-PC>:8080`, pulsa **Conectar**.
4. iOS pedirá permiso de **red local** la primera vez → Permitir.
5. Bloquea la pantalla / sal de la app → **el audio sigue** (background nativo).

## Ajustes

- El stepper **Buffer / latencia** baja/sube el jitter buffer. Empieza en 100 ms y
  baja hasta donde tu WiFi aguante sin que suban los *underruns*.
- Las features del servidor (PC mudo al conectar, no enviar en silencio) funcionan
  igual: la app las refleja en el estado y los stats.
