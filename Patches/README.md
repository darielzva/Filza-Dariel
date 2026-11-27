# Patches

Pon tus archivos `.3105` o `.dm` aquí. La app los detecta y aplica automáticamente al arrancar.

## Formato
- `.dm` — parche DarielModz (preferido)
- `.3105` — parche ThreeOneOSFive

## Cómo añadir un parche
1. Coloca el archivo `.dm` o `.3105` en esta carpeta
2. El `build.sh` lo copia al bundle en `Payload/WQFiles.app/Patches/`
3. Al arrancar la app, `WQPatchLoader` lo aplica si no estaba aplicado antes

## Estado
El archivo `applied_patches.json` en Documents guarda qué parches ya se aplicaron.
