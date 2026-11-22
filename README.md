# Mando Virtual — cliente Flutter (APK)

Cliente nativo Android del proyecto **Mando Virtual para Carreras**. Sustituye a la PWA del navegador y habla directamente con el servidor Python mediante WebSocket, usando el mismo protocolo binario `MVGP`.

> **Estado:** código completo y verificado contra `server/protocol.py`. La compilación del APK se hace en GitHub Actions porque la descarga del SDK de Flutter (~1.4 GB) es demasiado lenta desde esta conexión.

## Estructura

```
flutter_app_src/
├── lib/main.dart                       # Toda la app (UI + protocolo + giroscopio)
├── pubspec.yaml                        # Dependencias fijadas
├── android/app/src/main/AndroidManifest.xml
└── .github/workflows/build-apk.yml     # Compilación remota
```

## Compilar el APK (recomendado: GitHub Actions)

1. Crea un repositorio **vacío** en GitHub (por ejemplo `mando-virtual-apk`, sin README ni licencia iniciales).
2. El repositorio local ya está inicializado y con el commit hecho, así que solo falta:

   ```bash
   cd /home/Giovanni/MandoVirtualParaCarreras/flutter_app_src
   git remote add origin https://github.com/TU_USUARIO/mando-virtual-apk.git
   git branch -M main
   git push -u origin main
   ```

   > Si prefieres otro nombre de autor: `git config user.name "Tu Nombre"` y `git config user.email "tu@email.com"`, luego `git commit --amend --reset-author --no-edit`.

3. Entrar en GitHub → pestaña **Actions** → esperar el job *Build Flutter APK* (~5–10 min).
4. Al terminar, pulsa el artefacto **mando-virtual-apks** y descarga el ZIP.
5. Extrae el ZIP e instala en el móvil el APK que corresponda (casi siempre `app-arm64-v8a-release.apk`):

   ```bash
   adb install app-arm64-v8a-release.apk
   ```

   O copia el APK al teléfono y ábrelo desde el gestor de archivos (hay que permitir "instalar apps desconocidas").

El workflow ya genera la carpeta `android/` con `flutter create`, así que no hace falta subirla.

## Compilar en local (si algún día la red es rápida)

Necesitas Flutter 3.50.1 y Android SDK (platform 35, build-tools 35.0.0):

```bash
flutter create --platforms=android .
flutter pub get
flutter build apk --release --split-per-abi
```

Los APKs quedan en `build/app/outputs/flutter-apk/`.

## Uso

1. Arranca el servidor en la PC:

   ```bash
   cd /home/Giovanni/MandoVirtualParaCarreras
   python3 server/main.py
   ```

2. Abre la app en el móvil. Por defecto intenta `ws://192.168.0.104:8765/ws`.
3. Cambia la IP si hace falta (campo **URL WebSocket**).
4. Elige perfil y plantilla. El panel `/admin` de la PC refleja los paquetes/s.

### Giroscopio

El giroscopio del navegador exige HTTPS. En la app nativa **no hace falta HTTPS**: los sensores están disponibles por defecto. Activa el interruptor *Giroscopio* en el perfil Volante.

Si quieres cifrar también el WebSocket, usa `wss://192.168.0.104:8766/ws` (el servidor ya levanta HTTPS en 8766 con el certificado autofirmado de `scripts/gen-cert.sh`).

## Protocolo implementado

| Paquete | Tamaño | Contenido |
|---------|--------|-----------|
| Entrada (`0x01`) | 35 B | magic `MVGP`, seq, botones (uint16), 6 float32 (lx, ly, rx, ry, lt, rt) |
| Perfil (`0x02`) | 10 B | magic `MVGP`, seq, profile_id |

Frecuencia de envío: ~62 paquetes/s (cada 16 ms), igual que la PWA.

Perfiles: `0` Xbox 360, `1` Volante, `2` Yoke, `3` Teclado/Ratón.

## Solución de problemas

- **No conecta:** comprueba que el móvil y la PC estén en la misma Wi‑Fi y que el firewall permita el puerto 8765.
- **"La URL debe empezar por ws://":** escribe la URL completa, incluido `/ws` al final.
- **El servidor no ve paquetes:** revisa el campo de diagnóstico de la app; muestra los errores de WebSocket.
- **El panel no cambia de perfil:** la app recibe el comando JSON `{"cmd":"set_profile","profile_id":N}` y actualiza el layout automáticamente.
