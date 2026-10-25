#import "ONNXBridge.h"
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdocumentation"
#include "onnxruntime_cxx_api.h"
#pragma clang diagnostic pop
#include <memory>
#include <vector>

NSString *W2XRuntimeVersion(void) {
    const char *version = OrtGetApiBase()->GetVersionString();
    return version ? [NSString stringWithUTF8String:version] ?: @"Unknown" : @"Unknown";
}

@implementation W2XTensor
- (instancetype)initWithData:(NSData *)data shape:(NSArray<NSNumber *> *)shape integer:(BOOL)integer {
    if ((self = [super init])) { _data = data; _shape = shape; _integer = integer; }
    return self;
}
@end
static Ort::Env &environment() { static Ort::Env env(ORT_LOGGING_LEVEL_ERROR, "Waifu2x"); return env; }
static void assignError(NSError **error, const std::exception &e) {
    if (error) *error = [NSError errorWithDomain:@"Waifu2x.ONNX" code:1 userInfo:@{NSLocalizedDescriptionKey: @(e.what())}];
}
struct SessionBox {
    std::unique_ptr<Ort::Session> session;
    Ort::RunOptions options;
};
@implementation W2XSession { std::unique_ptr<SessionBox> _box; }
- (instancetype)initWithPath:(NSString *)path provider:(NSString *)provider inputShape:(NSArray<NSNumber *> *)inputShape error:(NSError **)error {
    return [self initWithPath:path provider:provider inputShape:inputShape threadCount:1 error:error];
}
- (instancetype)initWithPath:(NSString *)path provider:(NSString *)provider inputShape:(NSArray<NSNumber *> *)inputShape threadCount:(NSInteger)threadCount error:(NSError **)error {
    if (!(self = [super init])) return nil;
    try {
        _box = std::make_unique<SessionBox>();
        Ort::SessionOptions settings;
        settings.SetIntraOpNumThreads((int)MAX(1, MIN(8, threadCount)));
        settings.AddConfigEntry("session.intra_op.allow_spinning", "0");
        settings.SetInterOpNumThreads(1);
        settings.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        if ([provider isEqualToString:@"CoreML"] && inputShape.count > 0) {
            Ort::Session probe(environment(), path.fileSystemRepresentation, settings);
            auto type = probe.GetInputTypeInfo(0);
            auto info = type.GetTensorTypeAndShapeInfo();
            std::vector<const char *> symbolic(info.GetDimensionsCount());
            info.GetSymbolicDimensions(symbolic.data(), symbolic.size());
            for (size_t i=0; i<symbolic.size() && i<inputShape.count; i++) {
                if (symbolic[i] && symbolic[i][0]) Ort::ThrowOnError(Ort::GetApi().AddFreeDimensionOverrideByName(settings, symbolic[i], inputShape[i].longLongValue));
            }
        }
        if ([provider isEqualToString:@"CoreML"]) settings.AppendExecutionProvider("CoreML", {{"ModelFormat", "MLProgram"}, {"MLComputeUnits", "CPUAndGPU"}, {"RequireStaticInputShapes", "1"}});
        if ([provider isEqualToString:@"WebGPU"]) settings.AppendExecutionProvider("WebGPU", {});
        _box->session = std::make_unique<Ort::Session>(environment(), path.fileSystemRepresentation, settings);
        return self;
    } catch (const std::exception &e) { assignError(error, e); return nil; }
}
- (NSDictionary<NSString *,W2XTensor *> *)run:(NSDictionary<NSString *,W2XTensor *> *)inputs error:(NSError **)error {
    try {
        std::vector<const char *> names;
        std::vector<Ort::Value> values;
        auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        for (NSString *name in inputs) {
            W2XTensor *tensor = inputs[name];
            std::vector<int64_t> shape;
            for (NSNumber *d in tensor.shape) shape.push_back(d.longLongValue);
            names.push_back(name.UTF8String);
            values.push_back(Ort::Value::CreateTensor(memory, (void *)tensor.data.bytes, tensor.data.length,
                               shape.data(), shape.size(), tensor.integer ? ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 : ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT));
        }
        Ort::AllocatorWithDefaultOptions allocator;
        std::vector<Ort::AllocatedStringPtr> outputNames;
        std::vector<const char *> outputPointers;
        for (size_t i=0; i<_box->session->GetOutputCount(); i++) {
            outputNames.push_back(_box->session->GetOutputNameAllocated(i, allocator));
            outputPointers.push_back(outputNames.back().get());
        }
        auto outputs = _box->session->Run(_box->options, names.data(), values.data(), values.size(), outputPointers.data(), outputPointers.size());
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (size_t i=0; i<outputs.size(); i++) {
            auto info = outputs[i].GetTensorTypeAndShapeInfo();
            BOOL integer = info.GetElementType() == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
            auto dimensions = info.GetShape();
            NSMutableArray *shape = [NSMutableArray array];
            for (auto d : dimensions) [shape addObject:@(d)];
            NSData *data = [NSData dataWithBytes:outputs[i].GetTensorRawData() length:info.GetElementCount()*(integer ? 8:4)];
            result[@(outputPointers[i])] = [[W2XTensor alloc] initWithData:data shape:shape integer:integer];
        }
        return result;
    } catch (const std::exception &e) { assignError(error, e); return nil; }
}
- (void)cancel { if (_box) { try { _box->options.SetTerminate(); } catch (...) {} } }
+ (NSArray<NSString *> *)availableProviders {
    NSMutableArray *result = [NSMutableArray array];
    for (const auto &provider : Ort::GetAvailableProviders()) [result addObject:@(provider.c_str())];
    return result;
}
@end
