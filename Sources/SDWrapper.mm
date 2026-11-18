#import "SDWrapper.h"
#include <vector>
#include <string>

// Khai báo hàm main của sd-cli đã được llvm-objcopy đổi tên trong libsd_cli_all.a
extern "C" int sd_cli_main(int argc, const char **argv);

@implementation SDWrapper

+ (NSString *)modelsDirectoryPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = paths.firstObject;
    NSString *modelsDir = [docsDir stringByAppendingPathComponent:@"Models"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:modelsDir]) {
        [fm createDirectoryAtPath:modelsDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return modelsDir;
}

+ (NSString *)outputsDirectoryPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docsDir = paths.firstObject;
    NSString *outputsDir = [docsDir stringByAppendingPathComponent:@"Outputs"];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:outputsDir]) {
        [fm createDirectoryAtPath:outputsDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return outputsDir;
}

+ (NSArray<NSString *> *)listAvailableModels {
    NSString *modelsDir = [self modelsDirectoryPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:modelsDir error:nil];
    
    NSMutableArray<NSString *> *validModels = [NSMutableArray array];
    for (NSString *file in files) {
        NSString *ext = file.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"safetensors"] || [ext isEqualToString:@"gguf"] || [ext isEqualToString:@"ckpt"]) {
            [validModels addObject:file];
        }
    }
    return validModels;
}

+ (int)generateImageWithModelPath:(NSString *)modelPath
                           prompt:(NSString *)prompt
                   negativePrompt:(NSString *)negativePrompt
                       outputPath:(NSString *)outputPath
                            width:(int)width
                           height:(int)height
                            steps:(int)steps
                         cfgScale:(float)cfgScale
                             seed:(long long)seed
                          sampler:(NSString *)sampler {
    
    // Đảm bảo thư mục Documents/Models và Documents/Outputs luôn tồn tại
    [self modelsDirectoryPath];
    [self outputsDirectoryPath];

    std::vector<std::string> args;
    args.push_back("sd-cli");
    args.push_back("-m");
    args.push_back([modelPath UTF8String]);
    args.push_back("-p");
    args.push_back([prompt UTF8String]);
    
    if (negativePrompt && negativePrompt.length > 0) {
        args.push_back("-n");
        args.push_back([negativePrompt UTF8String]);
    }
    
    args.push_back("-o");
    args.push_back([outputPath UTF8String]);
    
    args.push_back("-W");
    args.push_back(std::to_string(width));
    
    args.push_back("-H");
    args.push_back(std::to_string(height));
    
    args.push_back("--steps");
    args.push_back(std::to_string(steps));
    
    args.push_back("--cfg-scale");
    args.push_back(std::to_string(cfgScale));
    
    args.push_back("-s");
    args.push_back(std::to_string(seed));
    
    if (sampler && sampler.length > 0) {
        args.push_back("--sampling-method");
        args.push_back([sampler UTF8String]);
    }

    // Chuyển sang mảng const char* chuẩn C
    std::vector<const char *> c_args;
    c_args.reserve(args.size());
    for (const auto &arg : args) {
        c_args.push_back(arg.c_str());
    }

    // Gọi trực tiếp engine C++ Metal
    return sd_cli_main((int)c_args.size(), c_args.data());
}

@end
