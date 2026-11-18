#import "SDWrapper.h"
#import <UIKit/UIKit.h>
#include <vector>
#include <string>

// Khai báo hàm entry-point được đổi tên từ examples/cli/main.cpp của stable-diffusion.cpp
extern "C" int sd_cli_main(int argc, const char **argv);

@implementation SDWrapper {
    dispatch_queue_t _renderQueue;
}

+ (instancetype)shared {
    static SDWrapper *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[SDWrapper alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderQueue = dispatch_queue_create("com.cuongte92.sdmetal.cli.queue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)cancelGeneration {
    // Tiến trình chạy theo từng lượt render
}

- (nullable NSString *)saveBase64ToTempPng:(nullable NSString *)base64Str filename:(NSString *)filename {
    if (!base64Str || base64Str.length == 0) return nil;
    NSRange commaRange = [base64Str rangeOfString:@","];
    NSString *cleanB64 = (commaRange.location != NSNotFound) ? [base64Str substringFromIndex:commaRange.location + 1] : base64Str;
    NSData *imgData = [[NSData alloc] initWithBase64EncodedString:cleanB64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!imgData) return nil;

    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    if ([imgData writeToFile:tempPath atomically:YES]) {
        return tempPath;
    }
    return nil;
}

- (void)generateImageWithModelPath:(NSString *)modelPath
                          loraPath:(nullable NSString *)loraPath
                      loraStrength:(float)loraStrength
                            prompt:(NSString *)prompt
                    negativePrompt:(NSString *)negativePrompt
                             width:(int)width
                            height:(int)height
                             steps:(int)steps
                          cfgScale:(float)cfgScale
                              seed:(int64_t)seed
                    initImageBase64:(nullable NSString *)initImageBase64
                    maskImageBase64:(nullable NSString *)maskImageBase64
                          denoise:(float)denoise
                          progress:(SDProgressBlock)progressBlock
                        completion:(SDCompletionBlock)completionBlock {

    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            dispatch_async(dispatch_get_main_queue(), ^{
                progressBlock(1, steps, 0.1f);
            });

            NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"sd_output.png"];
            [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];

            NSMutableString *finalPrompt = [prompt mutableCopy];
            NSString *loraDir = nil;
            if (loraPath && loraPath.length > 0) {
                loraDir = [loraPath stringByDeletingLastPathComponent];
                NSString *loraName = [[loraPath lastPathComponent] stringByDeletingPathExtension];
                [finalPrompt appendFormat:@" <lora:%@:%.2f>", loraName, loraStrength];
            }

            std::vector<std::string> args;
            args.push_back("sd-cli");
            args.push_back("-m");
            args.push_back([modelPath UTF8String]);
            args.push_back("-p");
            args.push_back([finalPrompt UTF8String]);
            args.push_back("-n");
            args.push_back([negativePrompt UTF8String]);
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
            args.push_back("--vae-tiling");
            args.push_back("--diffusion-fa");
            args.push_back("-o");
            args.push_back([outputPath UTF8String]);

            if (loraDir && loraDir.length > 0) {
                args.push_back("--lora-model-dir");
                args.push_back([loraDir UTF8String]);
            }

            NSString *initPath = [self saveBase64ToTempPng:initImageBase64 filename:@"sd_init.png"];
            if (initPath) {
                args.push_back("-i");
                args.push_back([initPath UTF8String]);
                args.push_back("--strength");
                args.push_back(std::to_string(denoise));
            }

            NSString *maskPath = [self saveBase64ToTempPng:maskImageBase64 filename:@"sd_mask.png"];
            if (maskPath) {
                args.push_back("--mask");
                args.push_back([maskPath UTF8String]);
            }

            std::vector<const char *> c_args;
            c_args.reserve(args.size());
            for (const auto &s : args) {
                c_args.push_back(s.c_str());
            }

            int ret = sd_cli_main((int)c_args.size(), c_args.data());

            NSData *pngData = [NSData dataWithContentsOfFile:outputPath];
            if (ret != 0 || !pngData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(nil, @"Lỗi sinh ảnh từ lõi Metal (kiểm tra lại file model .safetensors / .gguf).");
                });
                return;
            }

            NSString *b64Result = [NSString stringWithFormat:@"data:image/png;base64,%@", [pngData base64EncodedStringWithOptions:0]];
            dispatch_async(dispatch_get_main_queue(), ^{
                progressBlock(steps, steps, 1.0f);
                completionBlock(b64Result, nil);
            });
        }
    });
}

@end
