// DMFiles_ObjC.h — umbrella import
// Add this single line wherever you need the full DM Files stack.
//
// Required linker flags in build.sh:
//   -framework Foundation
//   -framework UIKit
//   -framework Security
//   -framework CommonCrypto          (usually implicit via Security on device)
//
// build.sh compile flags (add these to your clang invocation):
//   DMSupabaseService.m DMPatchesStore.m DMSplashViewController.m DMLoginViewController.m
//
// WQUI.m must expose:  extern void wq_install_remote_dm(NSURL *patchURL);
// If you're not using the auto-install hook, remove that extern from DMPatchesStore.m.

#import "DMSupabaseService.h"
#import "DMPatchesStore.h"
#import "DMSplashViewController.h"
#import "DMLoginViewController.h"
