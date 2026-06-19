# Instalar gratis (sin Mac, sin pagar) — GitHub Actions + Sideloadly

Genera el `.ipa` en un Mac de la nube (GitHub Actions) y lo firmas/instalas con
Sideloadly usando tu **Apple ID gratis**.

## 1. Subir el proyecto a GitHub

```bash
cd streamer-app
# crea un repo en github.com (Público = minutos de macOS ILIMITADOS gratis;
# Privado = ~limitado, los runners macOS cuentan 10x).
git remote add origin https://github.com/<tu-usuario>/streamer-app.git
git push -u origin main
```

## 2. Compilar el .ipa

- GitHub → pestaña **Actions** → workflow **"iOS unsigned IPA"** → **Run workflow**
  (o se dispara solo al hacer `push`).
- Tarda ~15-25 min. Al terminar, baja el artefacto **`app-unsigned-ipa`**
  (es un zip; dentro está `app-unsigned.ipa`).

> **El primer build probablemente falle compilando el Swift** (lo escribí sin Mac).
> Abre el job fallido, copia el error de la fase **"Compilar SIN firmar"** y
> pásamelo — lo arreglo y repetimos. Es normal, 1-3 iteraciones.

## 3. Firmar e instalar con Sideloadly (en Windows)

1. Instala **Sideloadly**: https://sideloadly.io  (y iTunes/iCloud de Apple si lo pide).
2. Conecta el iPhone por **USB** (la primera vez).
3. Abre Sideloadly, arrastra `app-unsigned.ipa`, pon tu **Apple ID**, pulsa **Start**.
   - Si tienes 2FA, te pedirá una *app-specific password* (te guía).
4. En el iPhone: **Ajustes → General → VPN y gestión de dispositivos** → confía en tu
   Apple ID de desarrollador.

## 4. Usar

1. PC: `cd streamer && npm start`.
2. iPhone en la **misma WiFi**.
3. Abre la app **PC Speaker**, escribe `ws://<ip-del-PC>:8080`, **Conectar**.
4. Permite el acceso a la **red local** cuando lo pida.
5. Bloquea la pantalla → el audio **sigue sonando** (background nativo). 🎧

## Límites de la cuenta gratis

- La app **caduca a los 7 días** → reinstálala con Sideloadly para refrescar.
  (Para que se refresque solo, mira **AltStore** o **SideStore**.)
- Máximo **3 apps** sideloadeadas a la vez con un Apple ID gratis.
- El **background audio sí funciona** con firma gratis (no es un permiso de pago).
