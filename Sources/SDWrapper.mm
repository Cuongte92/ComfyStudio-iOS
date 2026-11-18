#import "SDWrapper.h"
#import <UIKit/UIKit.h>
#include <vector>
#include <string>
#include <atomic>
#include <unistd.h>
#include <fcntl.h>

extern "C" int sd_cli_main(int argc, const char **argv);

@interface SDWrapper ()
@property (nonatomic, assign) BOOL isCancelled;
@property (nonatomic, strong) dispatch_queue_t genQueue;
@end

@implementation SDWrapper

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
        _genQueue = dispatch_queue_create("com.cuongte92.comfystudio.metal", DISPATCH_QUEUE_SERIAL);
        _isCancelled = NO;
    }
    return self;
}

- (void)cancelGeneration {
    self.isCancelled = YES;
}

// Giải mã chuỗi DataURL Base64 từ Canvas HTML thành file PNG tạm trên iPhone
- (nullable NSString *)saveBase64DataUrlToTempPNG:(nullable NSString *)dataUrl prefix:(NSString *)prefix {
    if (!dataUrl || dataUrl.length == 0) return nil;
    NSString *b64 = dataUrl;
    NSRange commaRange = [dataUrl rangeOfString:@","];
    if (commaRange.location != NSNotFound) {
        b64 = [dataUrl substringFromIndex:commaRange.location + 1];
    }
    NSData *rawData = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!rawData) return nil;

    UIImage *img = [UIImage imageWithData:rawData];
    if (!img) return nil;

    NSData *pngData = UIImagePNGRepresentation(img);
    if (!pngData) return nil;

    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%@_%lld.png", prefix, (long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
    if ([pngData writeToFile:tempPath atomically:YES]) {
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
                          progress:(nullable SDProgressBlock)progressBlock
                        completion:(SDCompletionBlock)completionBlock {
    self.isCancelled = NO;

    dispatch_async(self.genQueue, ^{
        NSDate *startTime = [NSDate date];
        NSFileManager *fm = [NSFileManager defaultManager];

        // 1. Chuẩn bị đường dẫn file ảnh xuất ra
        NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"sd_out_%lld.png", (long long)([[NSDate date] timeIntervalSince1970] * 1000)]];

        // 2. Xử lý Init Image (I2I / Inpaint) và Mask Image (Inpaint)
        NSString *initImgPath = [self saveBase64DataUrlToTempPNG:initImageBase64 prefix:@"sd_init"];
        NSString *maskImgPath = [self saveBase64DataUrlToTempPNG:maskImageBase64 prefix:@"sd_mask"];

        // 3. Xử lý LoRA theo chuẩn cú pháp của stable-diffusion.cpp (--lora-model-dir + <lora:name:weight>)
        NSString *finalPrompt = prompt ?: @"";
        NSString *loraDir = nil;
        if (loraPath && loraPath.length > 0 && [fm fileExistsAtPath:loraPath]) {
            loraDir = [loraPath stringByDeletingLastPathComponent];
            NSString *loraNameNoExt = [[loraPath lastPathComponent] stringByDeletingPathExtension];
            finalPrompt = [NSString stringWithFormat:@"%@ <lora:%@:%.2f>", finalPrompt, loraNameNoExt, loraStrength];
        }

        // 4. Dựng danh sách tham số CLI cho sd_cli_main
        std::vector<std::string> args;
        args.push_back("sd-cli");

        if (initImgPath) {
            args.push_back("-M");
            args.push_back("img2img");
            args.push_back("-i");
            args.push_back([initImgPath UTF8String]);
            args.push_back("--strength");
            args.push_back(std::to_string(denoise));

            if (maskImgPath) {
                args.push_back("--mask");
                args.push_back([maskImgPath UTF8String]);
            }
        }

        args.push_back("-m");
        args.push_back([modelPath UTF8String]);

        if (loraDir) {
            args.push_back("--lora-model-dir");
            args.push_back([loraDir UTF8String]);
        }

        args.push_back("-p");
        args.push_back([finalPrompt UTF8String]);

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

        // 5. Bắt luồng stdout/stderr bằng pipe (tách readFd thành biến int thường để dùng trong Obj-C block)
        int pipeFds[2];
        int savedStdout = dup(STDOUT_FILENO);
        int savedStderr = dup(STDERR_FILENO);
        bool pipeActive = (pipe(pipeFds) == 0);
        int readFd = pipeActive ? pipeFds[0] : -1;

        dispatch_source_t readSource = nil;
        __block std::string logTail;

        if (pipeActive) {
            dup2(pipeFds[1], STDOUT_FILENO);
            dup2(pipeFds[1], STDERR_FILENO);
            close(pipeFds[1]);

            fcntl(readFd, F_SETFL, O_NONBLOCK);
            readSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, readFd, 0, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));

            dispatch_source_set_event_handler(readSource, ^{
                char buf[1024];
                ssize_t bytesRead = read(readFd, buf, sizeof(buf) - 1);
                if (bytesRead > 0) {
                    buf[bytesRead] = '\0';
                    write(savedStdout, buf, bytesRead);

                    logTail.append(buf, bytesRead);
                    if (logTail.size() > 4096) {
                        logTail.erase(0, logTail.size() - 2048);
                    }

                    NSString *chunk = [NSString stringWithUTF8String:buf];
                    if (chunk) {
                        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)\\s*/\\s*(\\d+)" options:0 error:nil];
                        NSTextCheckingResult *match = [regex firstMatchInString:chunk options:0 range:NSMakeRange(0, chunk.length)];
                        if (match && match.numberOfRanges >= 3) {
                            int curStep = [[chunk substringWithRange:[match rangeAtIndex:1]] intValue];
                            int totSteps = [[chunk substringWithRange:[match rangeAtIndex:2]] intValue];
                            float elapsed = (float)[[NSDate date] timeIntervalSinceDate:startTime];
                            if (progressBlock && totSteps > 0 && curStep <= totSteps) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    progressBlock(curStep, totSteps, elapsed);
                                });
                            }
                        }
                    }
                }
            });

            dispatch_source_set_cancel_handler(readSource, ^{
                close(readFd);
            });
            dispatch_resume(readSource);
        }

        // 6. Chạy engine Metal C++
        std::vector<const char *> c_args;
        c_args.reserve(args.size());
        for (const auto &arg : args) {
            c_args.push_back(arg.c_str());
        }

        int exitCode = sd_cli_main((int)c_args.size(), c_args.data());

        // Khôi phục stdout/stderr
        fflush(stdout);
        fflush(stderr);
        if (pipeActive) {
            dup2(savedStdout, STDOUT_FILENO);
            dup2(savedStderr, STDERR_FILENO);
            if (readSource) dispatch_source_cancel(readSource);
        }
        close(savedStdout);
        close(savedStderr);

        // 7. Dọn file tạm đầu vào
        if (initImgPath) [fm removeItemAtPath:initImgPath error:nil];
        if (maskImgPath) [fm removeItemAtPath:maskImgPath error:nil];

        // 8. Đọc ảnh kết quả và trả về Base64 PNG cho WebView
        if (self.isCancelled) {
            [fm removeItemAtPath:outputPath error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(nil, @"Đã hủy quá trình tạo ảnh.");
            });
            return;
        }

        if (exitCode == 0 && [fm fileExistsAtPath:outputPath]) {
            NSData *outData = [NSData dataWithContentsOfFile:outputPath];
            [fm removeItemAtPath:outputPath error:nil];
            if (outData && outData.length > 0) {
                NSString *b64Png = [@"data:image/png;base64," stringByAppendingString:[outData base64EncodedStringWithOptions:0]];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(b64Png, nil);
                });
                return;
            }
        }

        NSString *errSummary = [NSString stringWithFormat:@"Engine dừng (mã %d). Kiểm tra lại định dạng model hoặc dung lượng RAM.", exitCode];
        dispatch_async(dispatch_get_main_queue(), ^{
            completionBlock(nil, errSummary);
        });
    });
}

@end
