// coreml_run — run a CoreML model on the ANE via the PUBLIC MLModel API.
// Inference needs no private APIs: CoreML auto-partitions onto the Neural Engine
// when computeUnits = All. This is the shippable inference runtime.
//
// Usage: coreml_run <model.mlpackage> <input.bin> <output.bin> <in_name> <out_name>
//   input.bin  : raw float32, shape inferred from the model's input description
//   output.bin : raw float32 logits written out
// Build: clang -fobjc-arc -framework Foundation -framework CoreML coreml_run.m -o coreml_run
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>

static MLMultiArray* fill(MLMultiArray *arr, NSData *data) {
    memcpy(arr.dataPointer, data.bytes, MIN((NSUInteger)arr.count*4, data.length));
    return arr;
}

int main(int argc, char **argv) {
    if (argc < 6) { fprintf(stderr, "usage: coreml_run model.mlpackage in.bin out.bin in_name out_name\n"); return 2; }
    @autoreleasepool {
        NSError *e = nil;
        NSString *pkg = @(argv[1]);
        NSString *inName = @(argv[4]), *outName = @(argv[5]);

        NSURL *compiled = [MLModel compileModelAtURL:[NSURL fileURLWithPath:pkg] error:&e];
        if (e) { fprintf(stderr, "compile: %s\n", e.description.UTF8String); return 1; }

        MLModelConfiguration *cfg = [MLModelConfiguration new];
        cfg.computeUnits = MLComputeUnitsAll;  // CPU + GPU + ANE; CoreML picks ANE where it can
        MLModel *model = [MLModel modelWithContentsOfURL:compiled configuration:cfg error:&e];
        if (e || !model) { fprintf(stderr, "load: %s\n", e.description.UTF8String); return 1; }

        // Build input MLMultiArray from the model's declared shape
        MLFeatureDescription *inDesc = model.modelDescription.inputDescriptionsByName[inName];
        if (!inDesc) { fprintf(stderr, "no input '%s'\n", argv[4]); return 1; }
        NSArray<NSNumber*> *shape = inDesc.multiArrayConstraint.shape;
        MLMultiArray *inArr = [[MLMultiArray alloc] initWithShape:shape
                                  dataType:MLMultiArrayDataTypeFloat32 error:&e];
        if (e) { fprintf(stderr, "inarr: %s\n", e.description.UTF8String); return 1; }
        fill(inArr, [NSData dataWithContentsOfFile:@(argv[2])]);

        MLDictionaryFeatureProvider *feats = [[MLDictionaryFeatureProvider alloc]
            initWithDictionary:@{inName: [MLFeatureValue featureValueWithMultiArray:inArr]} error:&e];
        id<MLFeatureProvider> out = [model predictionFromFeatures:feats error:&e];
        if (e || !out) { fprintf(stderr, "predict: %s\n", e.description.UTF8String); return 1; }

        MLMultiArray *logits = [out featureValueForName:outName].multiArrayValue;
        if (!logits) { fprintf(stderr, "no output '%s'\n", argv[5]); return 1; }
        NSData *outData = [NSData dataWithBytes:logits.dataPointer length:logits.count*4];
        [outData writeToFile:@(argv[3]) atomically:YES];
        fprintf(stderr, "ok: %lu floats -> %s\n", (unsigned long)logits.count, argv[3]);
    }
    return 0;
}
