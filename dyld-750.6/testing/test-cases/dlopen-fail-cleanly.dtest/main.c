
// BUILD:  $CC c.c -dynamiclib -o $BUILD_DIR/libcextra.dylib -install_name $RUN_DIR/libc.dylib -DEXTRA_SYMBOL=1
// BUILD:  $CC c.c -dynamiclib -o $BUILD_DIR/libc.dylib -install_name $RUN_DIR/libc.dylib
// BUILD:  $CC b.m -dynamiclib -o $BUILD_DIR/libb.dylib -install_name $RUN_DIR/libb.dylib $BUILD_DIR/libcextra.dylib -framework Foundation
// BUILD:  $CC a.c -dynamiclib -o $BUILD_DIR/liba.dylib -install_name $RUN_DIR/liba.dylib $BUILD_DIR/libb.dylib
// BUILD:  $CC main.c -DRUN_DIR="$RUN_DIR" -o $BUILD_DIR/dlopen-fail-cleanly.exe

// BUILD: $SKIP_INSTALL $BUILD_DIR/libcextra.dylib


// RUN:  ./dlopen-fail-cleanly.exe

#include <stdio.h>
#include <string.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>

#include "test_support.h"

int main(int argc, const char* argv[], const char* envp[], const char* apple[]) {
    // dlopen dylib chain that should fail
    void* handle = dlopen(RUN_DIR "/liba.dylib", RTLD_NOW);
    if ( handle != NULL ) {
        FAIL("dlopen(liba.dylib) expected to fail but did not");
    }

    // iterate loaded images and make sure no residue from failed dlopen
    const char* foundPath = NULL;
    int count = _dyld_image_count();
    for (int i=0; i < count; ++i) {
        const char* path = _dyld_get_image_name(i);
        LOG("path[%2d]=%s", i, path);
        if ( strstr(path, RUN_DIR "/lib") != NULL ) {
            FAIL("Found unexpected loaded image: %s", path);
        }
    }

    PASS("Success");
}

