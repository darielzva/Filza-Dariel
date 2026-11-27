#!/usr/bin/env python3
"""
restore_main.py

Descarga main.m del upstream original (kolbicz/WQFiles) y le aplica
los dos patches de DarielModz antes de compilar:
  1. #import "WQPatchLoader.h" despues de WQDir.h
  2. Llamada a [[WQPatchLoader shared] applyBundledPatchesIfNeeded]
     al final de scene:willConnectToSession:

Uso: python3 scripts/restore_main.py
Sale con codigo 0 si main.m quedo correcto, 1 si hubo error.
"""

import urllib.request
import sys
import os

UPSTREAM_URL = (
    "https://raw.githubusercontent.com/kolbicz/WQFiles/main/main.m"
)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(SCRIPT_DIR)
MAIN_PATH = os.path.join(ROOT, "main.m")


def fetch_upstream() -> str:
    print(f"[restore_main] Fetching {UPSTREAM_URL}")
    try:
        with urllib.request.urlopen(UPSTREAM_URL, timeout=30) as r:
            return r.read().decode("utf-8")
    except Exception as e:
        print(f"[restore_main] WARNING: could not fetch upstream: {e}")
        return ""


def patch_content(content: str) -> str:
    # 1. Import
    if '#import "WQPatchLoader.h"' not in content:
        content = content.replace(
            '#import "WQDir.h"',
            '#import "WQDir.h"\n#import "WQPatchLoader.h"',
            1,
        )
        print("[restore_main] Added #import WQPatchLoader.h")

    # 2. Loader call inside scene:willConnectToSession:
    if "applyBundledPatchesIfNeeded" not in content:
        old = "    self.window = window;\n}"
        new = (
            "    self.window = window;\n\n"
            "    // Parches DarielModz\n"
            "    [[WQPatchLoader shared] applyBundledPatchesIfNeeded];\n"
            "}"
        )
        content = content.replace(old, new, 1)
        print("[restore_main] Added applyBundledPatchesIfNeeded call")

    return content


def needs_restore() -> bool:
    if not os.path.exists(MAIN_PATH):
        return True
    size = os.path.getsize(MAIN_PATH)
    if size < 50_000:  # original tiene ~222KB; <50KB = truncado
        print(f"[restore_main] main.m too small ({size} bytes) — restoring")
        return True
    with open(MAIN_PATH) as f:
        content = f.read()
    if "int main(" not in content:
        print("[restore_main] main.m missing int main() — restoring")
        return True
    return False


def main():
    if needs_restore():
        upstream = fetch_upstream()
        if not upstream or "int main(" not in upstream:
            print("[restore_main] ERROR: upstream fetch failed or invalid")
            sys.exit(1)
        content = patch_content(upstream)
    else:
        with open(MAIN_PATH) as f:
            content = f.read()
        content = patch_content(content)

    with open(MAIN_PATH, "w") as f:
        f.write(content)

    # Validate
    with open(MAIN_PATH) as f:
        final = f.read()
    assert 'int main(' in final, "int main() missing after restore"
    assert '#import "WQPatchLoader.h"' in final, "import missing after patch"
    assert 'applyBundledPatchesIfNeeded' in final, "loader call missing after patch"
    print(f"[restore_main] OK — {len(final)} chars, {final.count(chr(10))} lines")


if __name__ == "__main__":
    main()
