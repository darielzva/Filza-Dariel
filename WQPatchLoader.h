// WQPatchLoader.h
// Filza-Dariel — Sistema de parches bundled
// Lee archivos .dm y .3105 desde Patches/ en el bundle y los aplica al arrancar.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Resultado de aplicar un parche.
typedef NS_ENUM(NSInteger, WQPatchResult) {
    WQPatchResultApplied = 0,      // Aplicado exitosamente
    WQPatchResultAlreadyApplied,   // Ya estaba aplicado (no se repite)
    WQPatchResultInvalidFormat,    // Archivo malformado
    WQPatchResultFileNotFound,     // No se encontró el archivo
    WQPatchResultError,            // Error genérico
};

/// Metadatos de un parche parseado.
@interface WQPatch : NSObject
@property (nonatomic, copy) NSString *name;       // patch_name
@property (nonatomic, copy) NSString *version;    // patch_version
@property (nonatomic, copy) NSString *author;     // patch_author
@property (nonatomic, copy) NSString *patchDescription; // patch_description
@property (nonatomic, copy) NSString *filename;   // nombre del archivo en bundle
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *settings; // todas las claves
@end

/// Carga y aplica parches .dm / .3105 desde el bundle.
@interface WQPatchLoader : NSObject

+ (instancetype)shared;

/// Aplica todos los parches en Patches/ del bundle que no estén ya aplicados.
/// Llama esto desde application:didFinishLaunchingWithOptions:
- (void)applyBundledPatchesIfNeeded;

/// Lista de parches disponibles en el bundle (aplicados o no).
- (NSArray<WQPatch *> *)availableBundledPatches;

/// Lista de nombres de parches ya aplicados.
- (NSArray<NSString *> *)appliedPatchNames;

/// Aplica un parche específico por su filename en el bundle.
- (WQPatchResult)applyPatchNamed:(NSString *)filename;

/// Resetea el estado — permite re-aplicar todos los parches (útil en debug).
- (void)resetAppliedPatches;

@end

NS_ASSUME_NONNULL_END
