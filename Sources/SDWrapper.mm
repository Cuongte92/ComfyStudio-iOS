#import "SDWrapper.h"
#import <UIKit/UIKit.h>
#include <vector>
#include <string>
#include <memory>
#include <cmath>
#include <unistd.h>
#include <fcntl.h>

#include <grpcpp/grpcpp.h>
#include "imageService.grpc.pb.h"
#include "config_generated.h"

extern "C" int sd_cli_main(int argc, const char **argv);

@interface SDWrapper ()
@property (nonatomic, assign) BOOL isCancelled;
@property (nonatomic, assign) BOOL isGRPCCancelled;
@property (nonatomic, strong) dispatch_queue_t genQueue;
@property (nonatomic, strong) dispatch_queue_t grpcQueue;
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
        _grpcQueue = dispatch_queue_create("com.cuongte92.comfystudio.dtgrpc", DISPATCH_QUEUE_SERIAL);
        _isCancelled = NO;
        _isGRPCCancelled = NO;
    }
    return self;
}

- (void)cancelGeneration {
    self.isCancelled = YES;
}

- (void)cancelDrawThingsGRPC {
    self.isGRPCCancelled = YES;
}

#pragma mark - Helper Functions

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

// Chuyển đổi Float16 (IEEE 754 half-precision) sang UInt8 [0..255] cho tensor của Draw Things
static inline uint8_t halfToByte(uint16_t h) {
    uint32_t s = (h & 0x8000) << 16;
    uint32_t e = (h & 0x7C00) >> 10;
    uint32_t m = (h & 0x03FF);
    uint32_t fBits = 0;
    if (e == 0) {
        if (m != 0) {
            e = 113;
            while ((m & 0x0400) == 0) { m <<= 1; e--; }
            m &= 0x03FF;
            fBits = s | (e << 23) | (m << 13);
        } else {
            fBits = s;
        }
    } else if (e == 31) {
        fBits = s | 0x7F800000 | (m << 13);
    } else {
        fBits = s | ((e + 112) << 23) | (m << 13);
    }
    float val;
    memcpy(&val, &fBits, sizeof(float));
    // Draw Things tensor nằm trong khoảng [-1, 1]
    float norm = (val + 1.0f) * 0.5f * 255.0f;
    if (norm < 0.0f) norm = 0.0f;
    if (norm > 255.0f) norm = 255.0f;
    return (uint8_t)(norm + 0.5f);
}

// Giải mã buffer ảnh trả về từ Draw Things gRPC (hỗ trợ PNG trực tiếp hoặc Raw Tensor Float16/Float32/UInt8)
- (nullable NSString *)decodeDrawThingsImageBytes:(const std::string &)rawBytes width:(int)w height:(int)h {
    if (rawBytes.empty()) return nil;
    NSData *data = [NSData dataWithBytes:rawBytes.data() length:rawBytes.size()];

    // Trường hợp 1: Server trả thẳng PNG/JPEG
    UIImage *directImg = [UIImage imageWithData:data];
    if (directImg) {
        NSData *png = UIImagePNGRepresentation(directImg);
        if (png) return [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
    }

    // Trường hợp 2: Raw Tensor nhị phân từ Draw Things (thường có header 68 bytes hoặc thuần pixel)
    size_t pixelCount = (size_t)w * (size_t)h;
    size_t halfTensorSize = pixelCount * 3 * 2;  // RGB Float16
    size_t halfTensorRGBA = pixelCount * 4 * 2;  // RGBA Float16
    size_t floatTensorSize = pixelCount * 3 * 4; // RGB Float32

    const uint8_t *ptr = (const uint8_t *)rawBytes.data();
    size_t len = rawBytes.size();

    // Bỏ qua header tensor của s4nnc/DrawThings nếu có (thường 68 bytes)
    if (len == halfTensorSize + 68 || len == halfTensorRGBA + 68 || len == floatTensorSize + 68) {
        ptr += 68;
        len -= 68;
    }

    std::vector<uint8_t> rgba(pixelCount * 4, 255);
    if (len == halfTensorSize) {
        const uint16_t *hPtr = (const uint16_t *)ptr;
        for (size_t i = 0; i < pixelCount; i++) {
            rgba[i * 4 + 0] = halfToByte(hPtr[i * 3 + 0]);
            rgba[i * 4 + 1] = halfToByte(hPtr[i * 3 + 1]);
            rgba[i * 4 + 2] = halfToByte(hPtr[i * 3 + 2]);
        }
    } else if (len == halfTensorRGBA) {
        const uint16_t *hPtr = (const uint16_t *)ptr;
        for (size_t i = 0; i < pixelCount; i++) {
            rgba[i * 4 + 0] = halfToByte(hPtr[i * 4 + 0]);
            rgba[i * 4 + 1] = halfToByte(hPtr[i * 4 + 1]);
            rgba[i * 4 + 2] = halfToByte(hPtr[i * 4 + 2]);
        }
    } else if (len == floatTensorSize) {
        const float *fPtr = (const float *)ptr;
        for (size_t i = 0; i < pixelCount; i++) {
            for (int c = 0; c < 3; c++) {
                float v = (fPtr[i * 3 + c] + 1.0f) * 0.5f * 255.0f;
                rgba[i * 4 + c] = (uint8_t)std::min(255.0f, std::max(0.0f, v + 0.5f));
            }
        }
    } else {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba.data(), w, h, 8, w * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef cgImg = CGBitmapContextCreateImage(ctx);
    UIImage *finalImg = [UIImage imageWithCGImage:cgImg];
    CGImageRelease(cgImg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(colorSpace);

    NSData *pngOut = UIImagePNGRepresentation(finalImg);
    if (!pngOut) return nil;
    return [@"data:image/png;base64," stringByAppendingString:[pngOut base64EncodedStringWithOptions:0]];
}

#pragma mark - Draw Things gRPC Client

- (std::shared_ptr<grpc::Channel>)createChannelForEndpoint:(NSString *)endpoint useTLS:(BOOL)useTLS {
    std::string target = [endpoint UTF8String];
    grpc::ChannelArguments args;
    args.SetMaxReceiveMessageSize(256 * 1024 * 1024); // 256MB cho ảnh 2K/4K
    args.SetMaxSendMessageSize(256 * 1024 * 1024);
    args.SetInt(GRPC_ARG_KEEPALIVE_TIME_MS, 20000);
    args.SetInt(GRPC_ARG_KEEPALIVE_TIMEOUT_MS, 10000);

    if (useTLS) {
        return grpc::CreateCustomChannel(target, grpc::SslCredentials(grpc::SslCredentialsOptions()), args);
    } else {
        return grpc::CreateCustomChannel(target, grpc::InsecureChannelCredentials(), args);
    }
}

- (void)connectDrawThingsGRPC:(NSString *)endpoint
                       useTLS:(BOOL)useTLS
                   completion:(DTConnectCompletionBlock)completion {
    dispatch_async(self.grpcQueue, ^{
        auto channel = [self createChannelForEndpoint:endpoint useTLS:useTLS];
        auto stub = ImageGenerationService::NewStub(channel);

        EchoRequest req;
        req.set_name("ComfyStudio-iOS");

        EchoReply reply;
        grpc::ClientContext ctx;
        ctx.set_deadline(std::chrono::system_clock::now() + std::chrono::seconds(20));

        grpc::Status status = stub->Echo(&ctx, req, &reply);
        if (!status.ok()) {
            NSString *err = [NSString stringWithFormat:@"Lỗi gRPC (%d): %s", status.error_code(), status.error_message().c_str()];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, nil, nil, err);
            });
            return;
        }

        NSMutableArray<NSString *> *models = [NSMutableArray array];
        NSMutableArray<NSString *> *loras = [NSMutableArray array];

        // Trích xuất danh sách file từ EchoReply.files
        for (int i = 0; i < reply.files_size(); i++) {
            NSString *fname = [NSString stringWithUTF8String:reply.files(i).c_str()];
            if (!fname || fname.length == 0) continue;
            NSString *lower = fname.lowercaseString;
            if ([lower containsString:@"lora"]) {
                [loras addObject:fname];
            } else if ([lower hasSuffix:@".ckpt"] || [lower hasSuffix:@".safetensors"] || [lower hasSuffix:@".gguf"]) {
                [models addObject:fname];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(YES, models, loras, nil);
        });
    });
}

- (void)generateWithDrawThingsGRPC:(NSString *)endpoint
                            useTLS:(BOOL)useTLS
                         modelName:(NSString *)modelName
                          loraName:(nullable NSString *)loraName
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
    self.isGRPCCancelled = NO;

    dispatch_async(self.grpcQueue, ^{
        NSDate *startTime = [NSDate date];
        auto channel = [self createChannelForEndpoint:endpoint useTLS:useTLS];
        auto stub = ImageGenerationService::NewStub(channel);

        // 1. Đóng gói GenerationConfiguration bằng FlatBuffers chuẩn Draw Things
        flatbuffers::FlatBufferBuilder fbb(4096);
        auto modelOffset = fbb.CreateString([modelName UTF8String]);

        std::vector<flatbuffers::Offset<LoRA>> loraOffsets;
        if (loraName && loraName.length > 0 && ![loraName isEqualToString:@"None"]) {
            auto loraFileOffset = fbb.CreateString([loraName UTF8String]);
            loraOffsets.push_back(CreateLoRA(fbb, loraFileOffset, loraStrength));
        }
        auto lorasVec = fbb.CreateVector(loraOffsets);

        // Draw Things tính kích thước theo đơn vị 64px (startWidth = width / 64)
        uint16_t startW = (uint16_t)std::max(1, width / 64);
        uint16_t startH = (uint16_t)std::max(1, height / 64);
        float strengthVal = (initImageBase64 && initImageBase64.length > 0) ? denoise : 1.0f;

        GenerationConfigurationBuilder cfgBuilder(fbb);
        cfgBuilder.add_id(0);
        cfgBuilder.add_start_width(startW);
        cfgBuilder.add_start_height(startH);
        cfgBuilder.add_seed((uint32_t)(seed & 0xFFFFFFFF));
        cfgBuilder.add_steps((uint32_t)steps);
        cfgBuilder.add_guidance_scale(cfgScale);
        cfgBuilder.add_strength(strengthVal);
        cfgBuilder.add_model(modelOffset);
        cfgBuilder.add_sampler(SamplerType_EulerA);
        cfgBuilder.add_batch_count(1);
        cfgBuilder.add_batch_size(1);
        cfgBuilder.add_loras(lorasVec);

        auto cfgOffset = cfgBuilder.Finish();
        fbb.Finish(cfgOffset);

        // 2. Tạo ImageGenerationRequest
        ImageGenerationRequest req;
        req.set_prompt([prompt UTF8String]);
        req.set_negative_prompt(negativePrompt ? [negativePrompt UTF8String] : "");
        req.set_configuration(fbb.GetBufferPointer(), fbb.GetSize());
        req.set_scale_factor(1);

        // Nếu có ảnh nguồn I2I / Inpaint
        if (initImageBase64 && initImageBase64.length > 0) {
            NSRange comma = [initImageBase64 rangeOfString:@","];
            NSString *b64 = (comma.location != NSNotFound) ? [initImageBase64 substringFromIndex:comma.location + 1] : initImageBase64;
            NSData *imgData = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (imgData) {
                req.set_image(imgData.bytes, imgData.length);
            }
        }
        if (maskImageBase64 && maskImageBase64.length > 0) {
            NSRange comma = [maskImageBase64 rangeOfString:@","];
            NSString *b64 = (comma.location != NSNotFound) ? [maskImageBase64 substringFromIndex:comma.location + 1] : maskImageBase64;
            NSData *maskData = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
            if (maskData) {
                req.set_mask(maskData.bytes, maskData.length);
            }
        }

        // 3. Gọi Streaming RPC GenerateImage
        grpc::ClientContext ctx;
        auto reader = stub->GenerateImage(&ctx, req);

        ImageGenerationResponse resp;
        std::string finalImageBytes;

        while (reader->Read(&resp)) {
            if (self.isGRPCCancelled) {
                ctx.TryCancel();
                break;
            }

            if (resp.has_current_signpost()) {
                const auto &sp = resp.current_signpost();
                if (sp.has_sampling()) {
                    int curStep = sp.sampling().step();
                    float elapsed = (float)[[NSDate date] timeIntervalSinceDate:startTime];
                    if (progressBlock) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            progressBlock(curStep, steps, elapsed);
                        });
                    }
                }
            }

            if (resp.generated_images_size() > 0) {
                finalImageBytes = resp.generated_images(0);
            }
        }

        grpc::Status status = reader->Finish();

        if (self.isGRPCCancelled) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(nil, @"Đã hủy tác vụ trên Draw Things gRPC.");
            });
            return;
        }

        if (!status.ok()) {
            NSString *err = [NSString stringWithFormat:@"Draw Things gRPC lỗi (%d): %s", status.error_code(), status.error_message().c_str()];
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(nil, err);
            });
            return;
        }

        NSString *b64Png = [self decodeDrawThingsImageBytes:finalImageBytes width:startW * 64 height:startH * 64];
        if (b64Png) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(b64Png, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(nil, @"Server trả về dữ liệu trống hoặc định dạng ảnh chưa giải mã được.");
            });
        }
    });
}

#pragma mark - Local A19 Pro Metal Engine

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

        NSString *outputPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"sd_out_%lld.png", (long long)([[NSDate date] timeIntervalSince1970] * 1000)]];

        NSString *initImgPath = [self saveBase64DataUrlToTempPNG:initImageBase64 prefix:@"sd_init"];
        NSString *maskImgPath = [self saveBase64DataUrlToTempPNG:maskImageBase64 prefix:@"sd_mask"];

        NSString *finalPrompt = prompt ?: @"";
        NSString *loraDir = nil;
        if (loraPath && loraPath.length > 0 && [fm fileExistsAtPath:loraPath]) {
            loraDir = [loraPath stringByDeletingLastPathComponent];
            NSString *loraNameNoExt = [[loraPath lastPathComponent] stringByDeletingPathExtension];
            finalPrompt = [NSString stringWithFormat:@"%@ <lora:%@:%.2f>", finalPrompt, loraNameNoExt, loraStrength];
        }

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

        int pipeFds[2];
        int savedStdout = dup(STDOUT_FILENO);
        int savedStderr = dup(STDERR_FILENO);
        bool pipeActive = (pipe(pipeFds) == 0);
        int readFd = pipeActive ? pipeFds[0] : -1;

        dispatch_source_t readSource = nil;

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

        std::vector<const char *> c_args;
        c_args.reserve(args.size());
        for (const auto &arg : args) {
            c_args.push_back(arg.c_str());
        }

        int exitCode = sd_cli_main((int)c_args.size(), c_args.data());

        fflush(stdout);
        fflush(stderr);
        if (pipeActive) {
            dup2(savedStdout, STDOUT_FILENO);
            dup2(savedStderr, STDERR_FILENO);
            if (readSource) dispatch_source_cancel(readSource);
        }
        close(savedStdout);
        close(savedStderr);

        if (initImgPath) [fm removeItemAtPath:initImgPath error:nil];
        if (maskImgPath) [fm removeItemAtPath:maskImgPath error:nil];

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
