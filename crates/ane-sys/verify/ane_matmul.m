#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <IOSurface/IOSurface.h>

static NSData* readFile(NSString *p){ return [NSData dataWithContentsOfFile:p]; }

int main() {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/AppleNeuralEngine", RTLD_NOW);
        NSError *e = nil;
        int K = 64, N = 48, S = 16;

        NSURL *compiled = [MLModel compileModelAtURL:
            [NSURL fileURLWithPath:@"/tmp/ane_matmul.mlpackage"] error:&e];
        if (e || !compiled) { printf("FAIL compile: %s\n", [[e description] UTF8String]); return 1; }
        NSData *milData = [[NSString stringWithContentsOfFile:
            [[compiled path] stringByAppendingPathComponent:@"model.mil"]
            encoding:NSUTF8StringEncoding error:nil] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *weightBlob = [NSData dataWithContentsOfFile:
            [[compiled path] stringByAppendingPathComponent:@"weights/weight.bin"]];
        printf("MIL: %lu bytes, weights: %lu bytes\n",
               (unsigned long)milData.length, (unsigned long)(weightBlob?weightBlob.length:0));

        Class Desc = NSClassFromString(@"_ANEInMemoryModelDescriptor");
        Class IMM  = NSClassFromString(@"_ANEInMemoryModel");
        Class AR   = NSClassFromString(@"_ANERequest");
        Class AIO  = NSClassFromString(@"_ANEIOSurfaceObject");

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
        if (!ok) { printf("FAIL ANE compile: %s\n", [[e description] UTF8String]); return 1; }
        ok = ((BOOL(*)(id,SEL,unsigned int,id,NSError**))objc_msgSend)(
            model, @selector(loadWithQoS:options:error:), 21, @{}, &e);
        if (!ok) { printf("FAIL ANE load: %s\n", [[e description] UTF8String]); return 1; }

        NSData *inData = readFile(@"/tmp/mm_input.bin");      // K*S floats
        NSData *expData = readFile(@"/tmp/mm_expected.bin");  // N*S floats
        const float *expected = (const float*)expData.bytes;

        NSUInteger inN = K*S, outN = N*S;
        NSUInteger inBytes = inN*4, outBytes = outN*4;
        IOSurfaceRef ioIn = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(inBytes),(id)kIOSurfaceHeight:@1,(id)kIOSurfaceBytesPerElement:@1,
            (id)kIOSurfaceBytesPerRow:@(inBytes),(id)kIOSurfaceAllocSize:@(inBytes),(id)kIOSurfacePixelFormat:@0});
        IOSurfaceRef ioOut = IOSurfaceCreate((__bridge CFDictionaryRef)@{
            (id)kIOSurfaceWidth:@(outBytes),(id)kIOSurfaceHeight:@1,(id)kIOSurfaceBytesPerElement:@1,
            (id)kIOSurfaceBytesPerRow:@(outBytes),(id)kIOSurfaceAllocSize:@(outBytes),(id)kIOSurfacePixelFormat:@0});
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
        printf("ANE evaluate: %s\n", ok?"YES":"NO");
        if (!ok) { printf("  err: %s\n", [[e description] UTF8String]); return 1; }

        IOSurfaceLock(ioOut, kIOSurfaceLockReadOnly, NULL);
        const float *outp = (const float*)IOSurfaceGetBaseAddress(ioOut);
        double maxErr = 0; int close = 0;
        for (NSUInteger i=0;i<outN;i++){
            double d = fabs((double)outp[i]-(double)expected[i]);
            if (d > maxErr) maxErr = d;
            if (d < 1e-2) close++;
        }
        printf("ANE out[0..3]      = %.4f %.4f %.4f\n", outp[0], outp[1], outp[2]);
        printf("expected out[0..3] = %.4f %.4f %.4f\n", expected[0], expected[1], expected[2]);
        printf("max abs error vs CPU reference: %.5f\n", maxErr);
        printf("within 1e-2: %d / %lu\n", close, (unsigned long)outN);
        printf(maxErr < 1e-2 ? ">>> ANE MATMUL MATCHES CPU <<<\n" : ">>> LAYOUT/VALUE MISMATCH <<<\n");
        IOSurfaceUnlock(ioOut, kIOSurfaceLockReadOnly, NULL);

        ((BOOL(*)(id,SEL,unsigned int,NSError**))objc_msgSend)(model, @selector(unloadWithQoS:error:), 21, &e);
        CFRelease(ioIn); CFRelease(ioOut);
        [fm removeItemAtPath:tmpDir error:nil];
    }
    return 0;
}
