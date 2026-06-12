// ane_run — generic ANE kernel executor.
// Usage: ane_run <model.mlpackage> <input.bin> <output.bin> <out_floats>
// Runs the model on the Apple Neural Engine (in-memory private-API path) with the
// raw float32 input, writes raw float32 output. Compilation is done offline
// (coremltools); this is the runtime executor the engine calls.
//
// Build: clang -fobjc-arc -framework Foundation -framework CoreML -framework IOSurface \
//          ane_run.m -o ane_run
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <IOSurface/IOSurface.h>

static IOSurfaceRef mkSurface(NSUInteger bytes) {
    return IOSurfaceCreate((__bridge CFDictionaryRef)@{
        (id)kIOSurfaceWidth:@(bytes),(id)kIOSurfaceHeight:@1,(id)kIOSurfaceBytesPerElement:@1,
        (id)kIOSurfaceBytesPerRow:@(bytes),(id)kIOSurfaceAllocSize:@(bytes),(id)kIOSurfacePixelFormat:@0});
}

int main(int argc, char **argv) {
    if (argc < 5) { fprintf(stderr, "usage: ane_run model.mlpackage in.bin out.bin out_floats\n"); return 2; }
    @autoreleasepool {
        NSString *pkg = [NSString stringWithUTF8String:argv[1]];
        NSString *inPath = [NSString stringWithUTF8String:argv[2]];
        NSString *outPath = [NSString stringWithUTF8String:argv[3]];
        NSUInteger outFloats = (NSUInteger)atoll(argv[4]);
        NSError *e = nil;

        dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW);

        NSURL *compiled = [MLModel compileModelAtURL:[NSURL fileURLWithPath:pkg] error:&e];
        if (e || !compiled) { fprintf(stderr, "compile failed: %s\n", [[e description] UTF8String]); return 1; }
        NSData *milData = [[NSString stringWithContentsOfFile:
            [[compiled path] stringByAppendingPathComponent:@"model.mil"]
            encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *weightBlob = [NSData dataWithContentsOfFile:
            [[compiled path] stringByAppendingPathComponent:@"weights/weight.bin"]];
        if (!milData) { fprintf(stderr, "no model.mil\n"); return 1; }

        Class Desc = NSClassFromString(@"_ANEInMemoryModelDescriptor");
        Class IMM  = NSClassFromString(@"_ANEInMemoryModel");
        Class AR   = NSClassFromString(@"_ANERequest");
        Class AIO  = NSClassFromString(@"_ANEIOSurfaceObject");

        NSDictionary *wdict = weightBlob ? @{
            @"@model_path/weights/weight.bin": @{@"offset": @64, @"data": weightBlob}} : @{};
        id desc = ((id(*)(Class,SEL,id,id,id))objc_msgSend)(
            Desc, @selector(modelWithMILText:weights:optionsPlist:), milData, wdict, nil);
        id model = ((id(*)(Class,SEL,id))objc_msgSend)(IMM, @selector(inMemoryModelWithDescriptor:), desc);
        id hexId = ((id(*)(id,SEL))objc_msgSend)(model, @selector(hexStringIdentifier));
        NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:hexId];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[tmpDir stringByAppendingPathComponent:@"weights"]
            withIntermediateDirectories:YES attributes:nil error:nil];
        [milData writeToFile:[tmpDir stringByAppendingPathComponent:@"model.mil"] atomically:YES];
        if (weightBlob) [weightBlob writeToFile:[tmpDir stringByAppendingPathComponent:@"weights/weight.bin"] atomically:YES];

        BOOL ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(
            model, @selector(compileWithQoS:options:error:), 21, @{}, &e);
        if (!ok) { fprintf(stderr, "ANE compile failed: %s\n", [[e description] UTF8String]); return 1; }
        ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(
            model, @selector(loadWithQoS:options:error:), 21, @{}, &e);
        if (!ok) { fprintf(stderr, "ANE load failed: %s\n", [[e description] UTF8String]); return 1; }

        NSData *inData = [NSData dataWithContentsOfFile:inPath];
        NSUInteger inBytes = inData.length, outBytes = outFloats * 4;
        IOSurfaceRef ioIn = mkSurface(inBytes), ioOut = mkSurface(outBytes);
        IOSurfaceLock(ioIn, 0, NULL);
        memcpy(IOSurfaceGetBaseAddress(ioIn), inData.bytes, inBytes);
        IOSurfaceUnlock(ioIn, 0, NULL);

        id wIn  = ((id(*)(Class,SEL,IOSurfaceRef))objc_msgSend)(AIO, @selector(objectWithIOSurface:), ioIn);
        id wOut = ((id(*)(Class,SEL,IOSurfaceRef))objc_msgSend)(AIO, @selector(objectWithIOSurface:), ioOut);
        id req = ((id(*)(Class,SEL,id,id,id,id,id,id,id))objc_msgSend)(AR,
            @selector(requestWithInputs:inputIndices:outputs:outputIndices:weightsBuffer:perfStats:procedureIndex:),
            @[wIn], @[@0], @[wOut], @[@0], nil, nil, @0);

        ok = ((BOOL(*)(id,SEL,unsigned int,id,id,NSError**))objc_msgSend)(
            model, @selector(evaluateWithQoS:options:request:error:), 21, @{}, req, &e);
        if (!ok) { fprintf(stderr, "ANE evaluate failed: %s\n", [[e description] UTF8String]); return 1; }

        IOSurfaceLock(ioOut, kIOSurfaceLockReadOnly, NULL);
        NSData *outData = [NSData dataWithBytes:IOSurfaceGetBaseAddress(ioOut) length:outBytes];
        IOSurfaceUnlock(ioOut, kIOSurfaceLockReadOnly, NULL);
        [outData writeToFile:outPath atomically:YES];

        ((BOOL(*)(id,SEL,unsigned int,NSError**))objc_msgSend)(model, @selector(unloadWithQoS:error:), 21, &e);
        CFRelease(ioIn); CFRelease(ioOut);
        [fm removeItemAtPath:tmpDir error:nil];
        fprintf(stderr, "ok: %lu floats -> %s\n", (unsigned long)outFloats, argv[3]);
    }
    return 0;
}
