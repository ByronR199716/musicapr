# Musica Pr — acceso por códigos

Versión no oficial de [SimpMusic](https://github.com/maxrave-dev/SimpMusic) (de maxrave-dev, licencia GPL-3.0)
con una pantalla de acceso por códigos tipo gift card y demos. Las donaciones van al creador original.

- `supabase/schema.sql`: base de datos y funciones (pegar en Supabase > SQL Editor > Run).
- `panel/index.html`: panel admin (configurar URL y clave de Supabase al inicio del script).
- Código de la pantalla de acceso: `composeApp/src/commonMain/kotlin/com/maxrave/simpmusic/access/`.
  La URL y la clave se configuran en `AccessConfig.kt`.
- El APK se compila con GitHub Actions (`.github/workflows/musicapr-apk.yml`).

Este proyecto se distribuye bajo GPL-3.0, igual que SimpMusic.
