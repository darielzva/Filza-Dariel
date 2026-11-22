//
// DMIntegration.h
// Declara los hooks que conectan DMLogin + DMSplash con el AppDelegate de WQFiles.
// Incluye este header en main.m (después de todos los #import existentes).
//
// Requisito: agregar al clang en build.sh:
//   DMSupabaseService.m DMPatchesStore.m DMSplashViewController.m DMLoginViewController.m
//
#import "DMLoginViewController.h"
#import "DMSplashViewController.h"
#import "DMPatchesStore.h"
#import "DMSupabaseService.h"

NS_ASSUME_NONNULL_BEGIN

/// Punto de entrada único. Llámalo desde -application:didFinishLaunchingWithOptions:
/// en lugar del código original que crea la ventana principal.
///
/// El flujo es:
///   1. Si hay una key guardada en Keychain → va directo al Splash
///   2. Si no hay key → muestra Login primero, después el Splash
///   3. Splash descarga parches de Supabase; al terminar muestra la UI principal (makeMainUI)
///
/// makeMainUI es el bloque que el AppDelegate ya usaba para construir su ventana;
/// lo extraes tal cual y lo pasas aquí.
///
void dm_start(UIWindow *window,
              void (^makeMainUI)(UIWindow *window));

NS_ASSUME_NONNULL_END
