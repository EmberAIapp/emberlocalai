// ANEForge - Minimal Objective-C bridge to Apple Neural Engine private APIs
// This file provides the thinnest possible ObjC layer; all logic lives in Rust.

#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <sys/sysctl.h>

// ============================================================================
// Types exported to Rust via FFI
// ============================================================================

typedef struct {
    void *model;      // _ANEInMemoryModel or compiled model handle
    void *request;    // _ANERequest
    void *client;     // _ANEClient shared ref
    IOSurfaceRef input_surface;
    IOSurfaceRef output_surface;
    int input_numel;
    int output_numel;
} ANEKernelHandle;

typedef struct {
    int chip_id;           // 0=unknown, 1=M1, 2=M2, 3=M3, 4=M4, 5=M5
    int ane_cores;
    float peak_tops;
    int64_t memory_bytes;
    char chip_name[64];
} ANEChipInfo;

// ============================================================================
// Private framework globals
// ============================================================================

static void *ane_framework_handle = NULL;
static Class ANECompilerClass = Nil;
static Class ANEClientClass = Nil;
static id shared_client = nil;
static int compilation_count = 0;

// ============================================================================
// Initialization
// ============================================================================

int ane_init(void) {
    if (ane_framework_handle) return 0; // Already initialized

    ane_framework_handle = dlopen(
        "/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine",
        RTLD_NOW
    );
    if (!ane_framework_handle) {
        NSLog(@"[ANEForge] Failed to load AppleNeuralEngine.framework: %s", dlerror());
        return -1;
    }

    // The ANEC compiler is a C function (ANECCompile) in ANECompiler.framework,
    // not an ObjC class. Load it too.
    void *compiler_handle = dlopen(
        "/System/Library/PrivateFrameworks/ANECompiler.framework/ANECompiler",
        RTLD_NOW
    );
    if (!compiler_handle) {
        NSLog(@"[ANEForge] Failed to load ANECompiler.framework: %s", dlerror());
        return -2;
    }

    ANEClientClass = objc_getClass("_ANEClient");
    if (!ANEClientClass) {
        NSLog(@"[ANEForge] Failed to find _ANEClient class");
        return -2;
    }

    // Real selector on modern macOS: +sharedConnection
    shared_client = ((id(*)(id, SEL))objc_msgSend)(
        (id)ANEClientClass,
        sel_registerName("sharedConnection")
    );

    if (!shared_client) {
        NSLog(@"[ANEForge] Failed to create ANE client");
        return -3;
    }

    NSLog(@"[ANEForge] ANE initialized successfully");
    return 0;
}

// ============================================================================
// Hardware Detection
// ============================================================================

int ane_detect_chip(ANEChipInfo *info) {
    memset(info, 0, sizeof(ANEChipInfo));

    // Use sysctl to detect chip
    size_t size = 64;
    char brand[64] = {0};
    if (sysctlbyname("machdep.cpu.brand_string", brand, &size, NULL, 0) == 0) {
        strncpy(info->chip_name, brand, 63);
    }

    // Detect memory
    int64_t memsize = 0;
    size = sizeof(memsize);
    sysctlbyname("hw.memsize", &memsize, &size, NULL, 0);
    info->memory_bytes = memsize;

    // Detect chip generation from model identifier or brand string
    if (strstr(brand, "M5") || strstr(brand, "T860")) {
        info->chip_id = 5;
        info->ane_cores = 16;
        info->peak_tops = 38.0f;
    } else if (strstr(brand, "M4") || strstr(brand, "T840")) {
        info->chip_id = 4;
        info->ane_cores = 16;
        info->peak_tops = 38.0f;
    } else if (strstr(brand, "M3") || strstr(brand, "T830")) {
        info->chip_id = 3;
        info->ane_cores = 16;
        info->peak_tops = 18.0f;
    } else if (strstr(brand, "M2") || strstr(brand, "T812")) {
        info->chip_id = 2;
        info->ane_cores = 16;
        info->peak_tops = 15.8f;
    } else if (strstr(brand, "M1") || strstr(brand, "T810")) {
        info->chip_id = 1;
        info->ane_cores = 16;
        info->peak_tops = 11.0f;
    } else {
        // Try reading IORegistry for ANE presence
        info->chip_id = 0;
        info->ane_cores = 0;
        info->peak_tops = 0.0f;
    }

    return info->chip_id > 0 ? 0 : -1;
}

// ============================================================================
// IOSurface Management
// ============================================================================

IOSurfaceRef ane_surface_create(int num_elements, int element_size) {
    int total_bytes = num_elements * element_size;

    // ANE expects channel-first layout: [1, C, 1, S]
    // IOSurface needs proper alignment
    int bytes_per_row = (total_bytes + 63) & ~63; // 64-byte aligned

    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(num_elements),
        (id)kIOSurfaceHeight: @1,
        (id)kIOSurfaceBytesPerElement: @(element_size),
        (id)kIOSurfaceBytesPerRow: @(bytes_per_row),
        (id)kIOSurfaceAllocSize: @(bytes_per_row),
        (id)kIOSurfacePixelFormat: @0x20202020, // Raw format
    };

    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    return surface;
}

int ane_surface_write(IOSurfaceRef surface, const void *data, int nbytes) {
    if (!surface || !data) return -1;

    IOSurfaceLock(surface, 0, NULL);
    void *base = IOSurfaceGetBaseAddress(surface);
    if (!base) {
        IOSurfaceUnlock(surface, 0, NULL);
        return -2;
    }
    memcpy(base, data, nbytes);
    IOSurfaceUnlock(surface, 0, NULL);
    return 0;
}

int ane_surface_read(IOSurfaceRef surface, void *data, int nbytes) {
    if (!surface || !data) return -1;

    IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    void *base = IOSurfaceGetBaseAddress(surface);
    if (!base) {
        IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
        return -2;
    }
    memcpy(data, base, nbytes);
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    return 0;
}

void ane_surface_destroy(IOSurfaceRef surface) {
    if (surface) {
        CFRelease(surface);
    }
}

// ============================================================================
// MIL Compilation
// ============================================================================

// Write MIL program files to temp directory for compilation
static NSString *write_mil_to_tempdir(const char *mil_text, const void *weights, int weight_bytes) {
    NSString *tmpdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"aneforge_%d_%d", getpid(), compilation_count]];

    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:tmpdir withIntermediateDirectories:YES attributes:nil error:nil];

    // Write MIL source
    NSString *mil_path = [tmpdir stringByAppendingPathComponent:@"model.mil"];
    NSString *mil_str = [NSString stringWithUTF8String:mil_text];
    [mil_str writeToFile:mil_path atomically:YES encoding:NSUTF8StringEncoding error:nil];

    // Write weights blob if provided
    if (weights && weight_bytes > 0) {
        NSString *weight_path = [tmpdir stringByAppendingPathComponent:@"weights.bin"];
        NSData *weight_data = [NSData dataWithBytes:weights length:weight_bytes];
        [weight_data writeToFile:weight_path atomically:YES];
    }

    // Write metadata
    NSString *meta_path = [tmpdir stringByAppendingPathComponent:@"model.mil.json"];
    NSDictionary *meta = @{
        @"version": @"1.0",
        @"modelName": @"aneforge_kernel",
    };
    NSData *meta_data = [NSJSONSerialization dataWithJSONObject:meta options:0 error:nil];
    [meta_data writeToFile:meta_path atomically:YES];

    return tmpdir;
}

int ane_compile(ANEKernelHandle *handle,
                const char *mil_text,
                const void *weights,
                int weight_bytes,
                int input_numel,
                int output_numel,
                int element_size) {
    if (!ane_framework_handle || !shared_client) return -1;

    @autoreleasepool {
        // Write MIL to temp directory
        NSString *tmpdir = write_mil_to_tempdir(mil_text, weights, weight_bytes);

        // Create compiler
        id compiler = ((id(*)(id, SEL))objc_msgSend)(
            (id)ANECompilerClass,
            sel_registerName("new")
        );
        if (!compiler) {
            NSLog(@"[ANEForge] Failed to create compiler");
            return -2;
        }

        // Compile MIL -> ANE binary
        NSError *error = nil;
        NSDictionary *options = @{};

        // Set input model path
        ((void(*)(id, SEL, id))objc_msgSend)(
            compiler,
            sel_registerName("setModelPath:"),
            tmpdir
        );

        id compiled = ((id(*)(id, SEL, int, id, NSError**))objc_msgSend)(
            compiler,
            sel_registerName("compileWithQoS:options:error:"),
            21, // QoS-21: high priority
            options,
            &error
        );

        if (!compiled || error) {
            NSLog(@"[ANEForge] Compilation failed: %@", error);
            // Cleanup
            [[NSFileManager defaultManager] removeItemAtPath:tmpdir error:nil];
            return -3;
        }

        // Load compiled model
        id model = ((id(*)(id, SEL, id, NSError**))objc_msgSend)(
            shared_client,
            sel_registerName("loadModel:error:"),
            compiled,
            &error
        );

        if (!model || error) {
            NSLog(@"[ANEForge] Model load failed: %@", error);
            [[NSFileManager defaultManager] removeItemAtPath:tmpdir error:nil];
            return -4;
        }

        // Create I/O surfaces
        IOSurfaceRef input_surf = ane_surface_create(input_numel, element_size);
        IOSurfaceRef output_surf = ane_surface_create(output_numel, element_size);

        if (!input_surf || !output_surf) {
            NSLog(@"[ANEForge] Failed to create IOSurfaces");
            [[NSFileManager defaultManager] removeItemAtPath:tmpdir error:nil];
            return -5;
        }

        // Create execution request
        id request = ((id(*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("_ANERequest"),
            sel_registerName("new")
        );

        // Configure request with I/O surfaces
        __unused id input_wrapper = ((id(*)(id, SEL, IOSurfaceRef))objc_msgSend)(
            (id)objc_getClass("_ANEIOSurfaceObject"),
            sel_registerName("initWithIOSurface:"),
            input_surf
        );

        __unused id output_wrapper = ((id(*)(id, SEL, IOSurfaceRef))objc_msgSend)(
            (id)objc_getClass("_ANEIOSurfaceObject"),
            sel_registerName("initWithIOSurface:"),
            output_surf
        );

        // Populate handle
        handle->model = (__bridge_retained void *)model;
        handle->request = (__bridge_retained void *)request;
        handle->client = (__bridge void *)shared_client;
        handle->input_surface = input_surf;
        handle->output_surface = output_surf;
        handle->input_numel = input_numel;
        handle->output_numel = output_numel;

        compilation_count++;

        // Cleanup temp directory
        [[NSFileManager defaultManager] removeItemAtPath:tmpdir error:nil];

        NSLog(@"[ANEForge] Kernel compiled (#%d), in=%d out=%d",
              compilation_count, input_numel, output_numel);
        return 0;
    }
}

// ============================================================================
// Kernel Execution
// ============================================================================

int ane_eval(ANEKernelHandle *handle) {
    if (!handle || !handle->model) return -1;

    @autoreleasepool {
        NSError *error = nil;
        id model = (__bridge id)handle->model;

        // Execute on ANE
        BOOL success = ((BOOL(*)(id, SEL, id, NSError**))objc_msgSend)(
            model,
            sel_registerName("evaluateWithRequest:error:"),
            (__bridge id)handle->request,
            &error
        );

        if (!success || error) {
            NSLog(@"[ANEForge] Eval failed: %@", error);
            return -2;
        }

        return 0;
    }
}

// ============================================================================
// Cleanup
// ============================================================================

void ane_kernel_destroy(ANEKernelHandle *handle) {
    if (!handle) return;

    if (handle->model) {
        CFRelease(handle->model);
        handle->model = NULL;
    }
    if (handle->request) {
        CFRelease(handle->request);
        handle->request = NULL;
    }
    if (handle->input_surface) {
        CFRelease(handle->input_surface);
        handle->input_surface = NULL;
    }
    if (handle->output_surface) {
        CFRelease(handle->output_surface);
        handle->output_surface = NULL;
    }
}

int ane_get_compilation_count(void) {
    return compilation_count;
}

void ane_reset_compilation_count(void) {
    compilation_count = 0;
}

void ane_shutdown(void) {
    shared_client = nil;
    if (ane_framework_handle) {
        dlclose(ane_framework_handle);
        ane_framework_handle = NULL;
    }
    compilation_count = 0;
}
