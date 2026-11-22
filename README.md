# Mando Virtual — cliente Flutter (APK)

Cliente nativo Android del proyecto **Mando Virtual para Carreras**. Sustituye a la PWA del navegador y habla directamente con el servidor Python mediante WebSocket, usando el mismo protocolo binario `MVGP`.

Repositorio: <https://github.com/Giovanni-LF/mando-virtual-apk>

> **Estado:** app completa, con modo carreras apaisado, HUD y giroscopio por acelerómetro. El build en GitHub Actions está verde (`Build Flutter APK`). La compilación se hace en la nube porque descargar Flutter + Android SDK localmente es demasiado lento en esta conexión.

---

## Índice

- [Estructura](#estructura)
- [Compilar el APK](#compilar-el-apk)
- [Instalación en el móvil](#instalación-en-el-móvil)
- [Uso](#uso)
- [Modo carreras](#modo-carreras)
- [Giroscopio](#giroscopio)
- [Protocolo implementado](#protocolo-implementado)
- [Solución de problemas](#solución-de-problemas)

---

## Estructura

```
flutter_app_src/
├── lib/main.dart                       # Toda la app: UI, protocolo, giroscopio, HUD
├── pubspec.yaml                        # Dependencias fijadas
└── .github/workflows/build-apk.yml     # Genera el proyecto Android y compila remotamente
```

El workflow ejecuta `flutter create --platforms=android` y después parchea el manifiesto generado para añadir:

- permisos de red (`INTERNET`, `ACCESS_NETWORK_STATE`),
- `usesCleartextTraffic="true"` (necesario para `ws://`),
- el nombre **Mando Virtual**.

Por eso `android/` no se versiona en el repositorio.

Dependencias: `flutter/material`, `flutter/services`, `sensors_plus` y `web_socket_channel`. No se añadieron paquetes externos para el diseño: todo se dibuja con `CustomPaint`, gradientes y sombras.

---

## Compilar el APK

El repositorio local ya tiene el remote configurado y el historial al día. Para lanzar un build:

```bash
cd /home/Giovanni/MandoVirtualParaCarreras/flutter_app_src
git push
```

En GitHub → **Actions** → workflow **Build Flutter APK** (~5–10 min):

1. `actions/setup-java@v5` con Java 21.
2. `flutter-action` con Flutter stable 3.50.1.
3. `flutter create --platforms=android --project-name mando_virtual .`
4. Parcheo del manifiesto (Python).
5. `rm -rf test` (elimina el test autogenerado, que referencia `material_ui`/`MyApp` y rompe `flutter analyze`).
6. `flutter pub get`
7. `flutter analyze --no-fatal-warnings --no-fatal-infos`
8. `flutter build apk --release --split-per-abi`

Al terminar, descarga el artefacto **`mando-virtual-apks`**. Los APKs se generan separados por arquitectura.

### Compilar en local (si algún día la red es rápida)

Necesitas Flutter 3.50.1 y Android SDK (platform 35, build-tools 35.0.0):

```bash
flutter create --platforms=android --project-name mando_virtual .
flutter pub get
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter build apk --release --split-per-abi
```

Los APKs quedan en `build/app/outputs/flutter-apk/`.

>Si editas `lib/main.dart`, comprueba siempre que compile antes de hacer `git push`: cada push dispara un build de ~10 min.

---

## Instalación en el móvil

1. Descarga el ZIP del artefacto y extráelo.
2. Instala `app-arm64-v8a-release.apk` (caso habitual en móviles modernos):

   ```bash
   adb install app-arm64-v8a-release.apk
   ```

3. O copia el APK al teléfono y ábrelo desde el gestor de archivos (hay que permitir "instalar apps desconocidas").

Si tu móvil es de 32 bits usa `app-armeabi-v7a-release.apk`; para x86_64, `app-x86_64-release.apk`.

---

## Uso

1. Arranca el servidor en la PC:

   ```bash
   cd /home/Giovanni/MandoVirtualParaCarreras
   python3 server/main.py
   ```

2. Abre la app. Por defecto intenta `ws://192.168.0.104:8765/ws`.
3. Cambia la IP si hace falta en el campo **URL WebSocket** (debe terminar en `/ws`).
4. Elige **Perfil** y **Plantilla** en los desplegables. El panel `/admin` de la PC refleja los paquetes/s.
5. Para desconectar, pulsa el botón de encendido (⏻) en la esquina superior.

El cambio de perfil también puede venir del PC: la app recibe `{"cmd":"set_profile","profile_id":N}` y actualiza el layout automáticamente.

---

## Modo carreras

Al conectar con el **perfil Volante** (`1`), la app entra en pantalla apaisada inmersiva (sin AppBar ni scroll), con:

| Zona | Controles |
|------|-----------|
| Izquierda | Volante arrastrable con el dedo, botones **GYRO** y **CENTRAR** |
| Centro | Marchas `+`/`−`, indicador de marcha y freno de mano |
| Derecha | Pedales **FRENO** y **GAS**, embrague y botones A/B/X/Y/BACK/START |
| Overlay | Estado `EN LÍNEA`, contador `PPS`, ⚙️ ajustes y ⏻ desconectar |

Estética neón + carbono: fondo con degradado radial, textura diagonal y rejilla; aro con glow, arco de giro con marcas y zonas rojas; pedales con relleno y reglón de escala.

### Datos del HUD

- **Marcha:** contador local (`R`, `0`–`6`) derivado de las pulsaciones de `+`/`−`. El protocolo no transmite la marcha del juego, así que no se sincroniza con cambios automáticos del juego.
- **PPS:** paquetes por segundo reales, contados en `_sendPacket()`.
- **Ángulo y presión de pedales:** valores reales enviados al servidor.

### Multi-touch

Los controles usan `Listener` con IDs de pointer independientes, así que puedes **girar + acelerar + frenar simultáneamente** sin que un gesto cancele otro.

---

## Giroscopio

A diferencia de la PWA, la app nativa **no necesita HTTPS** para acceder a los sensores; funciona sobre `ws://`.

1. Pulsa **GYRO OFF** para activarlo.
2. Pulsa **CENTRAR** con el móvil en la postura en la que vas a jugar (apaisado, de pie o inclinado).
3. Inclina lateralmente para girar el volante.

Ajustes disponibles en ⚙️:

| Ajuste | Qué hace |
|--------|----------|
| **Invertir** | Invierte el sentido del giro (útil al rotar el móvil 180° o cambiar de landscape-left a right) |
| **Rango (°)** | Grados de inclinación necesarios para llegar al extremo (15–45°, por defecto 30°) |
| **Suavizado** | Filtro paso bajo que quita saltos (0.05–0.60, por defecto 0.20) |
| **Zona muerta** | Zona central sin respuesta, compartida con la calibración general |

El sensor usado es el **acelerómetro** (inclinación absoluta mediante `atan2`), no el giroscopio de velocidad angular. Por eso el volante **no vuelve al centro solo** al dejar de mover el móvil. La calibración se aplica una sola vez, antes de enviar el paquete.

Si quieres cifrar también el WebSocket, usa `wss://192.168.0.104:8766/ws` (el servidor levanta HTTPS en 8766 si existe el certificado de `scripts/gen-cert.sh`).

---

## Protocolo implementado

| Paquete | Tamaño | Contenido |
|---------|--------|-----------|
| Entrada (`0x01`) | 35 B | magic `MVGP`, seq, botones (uint16), 6 float32: `lx, ly, rx, ry, lt, rt` |
| Perfil (`0x02`) | 10 B | magic `MVGP`, seq, `profile_id` |

Frecuencia de envío: ~62 paquetes/s (cada 16 ms), igual que la PWA.

Perfiles: `0` Xbox 360, `1` Volante, `2` Yoke, `3` Teclado/Ratón.

En el perfil Volante: `lx` = volante, `ly` = acelerador, `rx` = freno, `ry` = embrague; bits `4`/`5` = subir/bajar marcha, bit `1` = freno de mano.

---

## Solución de problemas

| Síntoma | Solución |
|---------|----------|
| No conecta | Comprueba que móvil y PC estén en la misma Wi‑Fi y que el firewall permita 8765. |
| "La URL debe empezar por ws://" | Escribe la URL completa, incluido `/ws` al final. |
| El servidor no ve paquetes | Revisa el panel **Diagnóstico** de la app; muestra los errores de WebSocket. |
| El panel no cambia de perfil | Comprueba que el comando JSON `set_profile` llegue al cliente (en el diagnóstico). |
| El giroscopio va al revés | Pulsa **CENTRAR** y activa **Invertir** en ⚙️. |
| El giroscopio tiembla | Sube **Suavizado** o baja **Rango**. |
| GitHub Actions falla en `flutter analyze` | Revisa que no exista `test/` y que `sensors_plus` sea 7.1.1 o superior. |
| GitHub Actions falla al compilar | Comprueba que el workflow use Java 21. |
