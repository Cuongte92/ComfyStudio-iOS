#import "SDWrapper.h"
#import <UIKit/UIKit.h>
#include "stable-diffusion.h"
#include <vector>
#include <string>

static SDProgressBlock g_currentProgressBlock = nil;
static bool g_shouldCancel = false;

static void sd_progress_callback(int step, int steps, float time, void* data) {
    if (g_currentProgressBlock) {
        SDProgressBlock block = g_currentProgressBlock;
        dispatch_async(dispatch_get_main_queue(), ^{
            block(step, steps, time);
        });
    }
}

@implementation SDWrapper {
    sd_ctx_t* _ctx;
    NSString* _loadedModelPath;
    NSString* _loadedLoraDir;
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
        _ctx = nullptr;
        _loadedModelPath = @"";
        _renderQueue = dispatch_queue_create("com.cuongte92.sdmetal.queue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)cancelGeneration {
    g_shouldCancel = true;
}

- (sd_image_t)sdImageFromBase64:(NSString *)base64Str targetW:(int)w targetH:(int)h isMask:(BOOL)isMask {
    sd_image_t empty = {0, 0, 0, nullptr};
    if (!base64Str || base64Str.length == 0) return empty;

    NSRange commaRange = [base64Str rangeOfString:@","];
    NSString *cleanB64 = (commaRange.location != NSNotFound) ? [base64Str substringFromIndex:commaRange.location + 1] : base64Str;
    NSData *imgData = [[NSData alloc] initWithBase64EncodedString:cleanB64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!imgData) return empty;

    UIImage *uiImg = [UIImage imageWithData:imgData];
    if (!uiImg) return empty;

    uint32_t channels = isMask ? 1 : 3;
    uint8_t *rawBuffer = (uint8_t *)malloc(w * h * channels);
    if (!rawBuffer) return empty;

    CGColorSpaceRef colorSpace = isMask ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB();
    size_t bytesPerRow = w * (isMask ? 1 : 4);
    uint8_t *rgbaBuffer = isMask ? rawBuffer : (uint8_t *)malloc(w * h * 4);

    CGBitmapInfo bitmapInfo = isMask ? kCGImageAlphaNone : (kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextRef context = CGBitmapContextCreate(rgbaBuffer, w, h, 8, bytesPerRow, colorSpace, bitmapInfo);
    CGContextDrawImage(context, CGRectMake(0, 0, w, h), uiImg.CGImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    if (!isMask) {
        for (int i = 0; i < w * h; i++) {
            rawBuffer[i * 3 + 0] = rgbaBuffer[i * 4 + 0];
            rawBuffer[i * 3 + 1] = rgbaBuffer[i * 4 + 1];
            rawBuffer[i * 3 + 2] = rgbaBuffer[i * 4 + 2];
        }
        free(rgbaBuffer);
    }

    sd_image_t result = {(uint32_t)w, (uint32_t)h, channels, rawBuffer};
    return result;
}

- (NSString *)base64PngFromSDImage:(sd_image_t)img {
    if (!img.data || img.width == 0 || img.height == 0) return nil;

    int w = img.width;
    int h = img.height;
    uint8_t *rgba = (uint8_t *)malloc(w * h * 4);
    for (int i = 0; i < w * h; i++) {
        rgba[i * 4 + 0] = img.data[i * 3 + 0];
        rgba[i * 4 + 1] = img.data[i * 3 + 1];
        rgba[i * 4 + 2] = img.data[i * 3 + 2];
        rgba[i * 4 + 3] = 255;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(rgba, w, h, 8, w * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef cgImage = CGBitmapContextCreateImage(context);
    UIImage *uiImage = [UIImage imageWithCGImage:cgImage];

    CGImageRelease(cgImage);
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    free(rgba);

    NSData *pngData = UIImagePNGRepresentation(uiImage);
    if (!pngData) return nil;
    return [NSString stringWithFormat:@"data:image/png;base64,%@", [pngData base64EncodedStringWithOptions:0]];
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
    g_shouldCancel = false;
    g_currentProgressBlock = progressBlock;

    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            sd_set_progress_callback(sd_progress_callback, nullptr);

            NSString *loraDir = loraPath.length > 0 ? [loraPath stringByDeletingLastPathComponent] : @"";

            // Nạp lại context nếu đổi model
            if (!self->_ctx || ![self->_loadedModelPath isEqualToString:modelPath] || ![self->_loadedLoraDir isEqualToString:loraDir]) {
                if (self->_ctx) {
                    free_sd_ctx(self->_ctx);
                    self->_ctx = nullptr;
                }

                sd_ctx_params_t ctx_params;
                sd_ctx_params_init(&ctx_params);
                ctx_params.model_path = [modelPath UTF8String];
                if (loraDir.length > 0) {
                    ctx_params.lora_model_dir = [loraDir UTF8String];
                }
                ctx_params.vae_decode_only = (initImageBase64 == nil);
                ctx_params.free_params_immediately = false;
                ctx_params.n_threads = 4;
                ctx_params.wtype = SD_TYPE_COUNT; // Tự động theo file model
                ctx_params.rng_type = STD_DEFAULT_RNG;
                ctx_params.keep_clip_on_cpu = false;
                ctx_params.keep_vae_on_cpu = false;
                ctx_params.diffusion_flash_attn = true; // Tối ưu bộ nhớ trên chip A19 Pro

                self->_ctx = new_sd_ctx(&ctx_params);
                if (!self->_ctx) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completionBlock(nil, @"Không thể nạp model! Hãy kiểm tra định dạng (.safetensors / .gguf) hoặc dung lượng RAM.");
                    });
                    return;
                }
                self->_loadedModelPath = modelPath;
                self->_loadedLoraDir = loraDir;
            }

            // Ghép cú pháp LoRA vào prompt nếu có chọn LoRA
            NSMutableString *finalPrompt = [prompt mutableCopy];
            if (loraPath && loraPath.length > 0) {
                NSString *loraName = [[loraPath lastPathComponent] stringByDeletingPathExtension];
                [finalPrompt appendFormat:@" <lora:%@:%.2f>", loraName, loraStrength];
            }

            sd_img_gen_params_t gen_params;
            sd_img_gen_params_init(&gen_params);
            gen_params.prompt = [finalPrompt UTF8String];
            gen_params.negative_prompt = [negativePrompt UTF8String];
            gen_params.width = width;
            gen_params.height = height;
            gen_params.sample_params.sample_steps = steps;
            gen_params.sample_params.guidance.txt_cfg = cfgScale;
            gen_params.sample_params.sample_method = EULER_A;
            gen_params.seed = seed;
            gen_params.batch_count = 1;
            gen_params.vae_tiling = true; // Chống tràn RAM khi render 1024x1024

            sd_image_t initImg = {0, 0, 0, nullptr};
            sd_image_t maskImg = {0, 0, 0, nullptr};

            if (initImageBase64 && initImageBase64.length > 0) {
                initImg = [self sdImageFromBase64:initImageBase64 targetW:width targetH:height isMask:NO];
                if (initImg.data) {
                    gen_params.init_image = initImg;
                    gen_params.strength = denoise;
                }
            }

            if (maskImageBase64 && maskImageBase64.length > 0) {
                maskImg = [self sdImageFromBase64:maskImageBase64 targetW:width targetH:height isMask:YES];
                if (maskImg.data) {
                    gen_params.mask_image = maskImg;
                }
            }

            sd_image_t *results = generate_image(self->_ctx, &gen_params);

            if (initImg.data) free(initImg.data);
            if (maskImg.data) free(maskImg.data);

            if (!results || !results[0].data) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(nil, @"Lỗi trong quá trình sinh ảnh trên GPU Metal.");
                });
                return;
            }

            NSString *b64Result = [self base64PngFromSDImage:results[0]];
            free(results[0].data);
            free(results);

            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(b64Result, nil);
            });
        }
    });
}

@end
