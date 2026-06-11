#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <IOSurface/IOSurface.h>

int main() {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW);
        NSError *e = nil;
        int C = 64, S = 32;

        // 1) Compile the .mlmodel via CoreML -> .mlmodelc (gives valid MIL + weights)
        NSURL *compiled = [MLModel compileModelAtURL:
            [NSURL fileURLWithPath:@"/tmp/ane_test.mlpackage"] error:&e];
        if (e || !compiled) { printf("FAIL compile mlmodel: %s\n", [[e description] UTF8String]); return 1; }

        NSData *milData = [[NSString stringWithContentsOfFile:
            [[compiled path] stringByAppendingPathComponent:@"model.mil"]
            encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *weightBlob = [NSData dataWithContentsOfFile:
            [[compiled path] stringByAppendingPathComponent:@"weights/weight.bin"]];
        if (!milData) { printf("FAIL: no model.mil\n"); return 1; }
        printf("MIL: %lu bytes, weights: %lu bytes\n",
               (unsigned long)milData.length, (unsigned long)(weightBlob?weightBlob.length:0));

        // 2) In-memory ANE model (the WORKING private-API path on M5/H16)
        Class Desc = NSClassFromString(@"_ANEInMemoryModelDescriptor");
        Class IMM  = NSClassFromString(@"_ANEInMemoryModel");
        Class AR   = NSClassFromString(@"_ANERequest");
        Class AIO  = NSClassFromString(@"_ANEIOSurfaceObject");
        if (!Desc || !IMM || !AR || !AIO) { printf("FAIL: private classes missing\n"); return 1; }

        NSDictionary *wdict = weightBlob ? @{
            @"@model_path/weights/weight.bin": @{@"offset": @64, @"data": weightBlob}
        } : @{};
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
        printf("ANE compile: %s\n", ok?"YES":"NO");
        if (!ok) { printf("  err: %s\n", [[e description] UTF8String]); return 1; }

        ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(
            model, @selector(loadWithQoS:options:error:), 21, @{}, &e);
        printf("ANE load: %s\n", ok?"YES":"NO");
        if (!ok) { printf("  err: %s\n", [[e description] UTF8String]); return 1; }

        // 3) IO surfaces. Fill input with 1.0, expect output 2.0
        NSUInteger n = C * S, bytes = n * 4;
        IOSurfaceRef ioIn = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(bytes),(id)kIOSurfaceHeight:@1,
            (id)kIOSurfaceBytesPerElement:@1,(id)kIOSurfaceBytesPerRow:@(bytes),
            (id)kIOSurfaceAllocSize:@(bytes),(id)kIOSurfacePixelFormat:@0});
        IOSurfaceRef ioOut = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(bytes),(id)kIOSurfaceHeight:@1,
            (id)kIOSurfaceBytesPerElement:@1,(id)kIOSurfaceBytesPerRow:@(bytes),
            (id)kIOSurfaceAllocSize:@(bytes),(id)kIOSurfacePixelFormat:@0});
        IOSurfaceLock(ioIn, 0, NULL);
        float *inp = (float*)IOSurfaceGetBaseAddress(ioIn);
        for (NSUInteger i=0;i<n;i++) inp[i] = 1.0f;
        IOSurfaceUnlock(ioIn, 0, NULL);

        id wIn  = ((id(*)(Class,SEL,IOSurfaceRef))objc_msgSend)(AIO, @selector(objectWithIOSurface:), ioIn);
        id wOut = ((id(*)(Class,SEL,IOSurfaceRef))objc_msgSend)(AIO, @selector(objectWithIOSurface:), ioOut);
        id req = ((id(*)(Class,SEL,id,id,id,id,id,id,id))objc_msgSend)(AR,
            @selector(requestWithInputs:inputIndices:outputs:outputIndices:weightsBuffer:perfStats:procedureIndex:),
            @[wIn], @[@0], @[wOut], @[@0], nil, nil, @0);

        ok = ((BOOL(*)(id,SEL,unsigned int,id,id,NSError**))objc_msgSend)(
            model, @selector(evaluateWithQoS:options:request:error:), 21, @{}, req, &e);
        printf("ANE evaluate: %s\n", ok?"YES":"NO");
        if (!ok) { printf("  err: %s\n", [[e description] UTF8String]); return 1; }

        IOSurfaceLock(ioOut, kIOSurfaceLockReadOnly, NULL);
        float *outp = (float*)IOSurfaceGetBaseAddress(ioOut);
        float v0 = outp[0], v1 = outp[1], vlast = outp[n-1];
        int correct = 0;
        for (NSUInteger i=0;i<n;i++) if (fabsf(outp[i]-2.0f) < 1e-3) correct++;
        IOSurfaceUnlock(ioOut, kIOSurfaceLockReadOnly, NULL);

        printf("\n=== RESULT ===\n");
        printf("input = 1.0 everywhere, model computes 2*input\n");
        printf("output[0]=%.4f  output[1]=%.4f  output[last]=%.4f\n", v0, v1, vlast);
        printf("correct (==2.0): %d / %lu\n", correct, (unsigned long)n);
        printf(correct == (int)n ? ">>> ANE EXECUTION VERIFIED <<<\n" : ">>> mismatch <<<\n");

        ((BOOL(*)(id,SEL,unsigned int,NSError**))objc_msgSend)(model, @selector(unloadWithQoS:error:), 21, &e);
        CFRelease(ioIn); CFRelease(ioOut);
        [fm removeItemAtPath:tmpDir error:nil];
    }
    return 0;
}
