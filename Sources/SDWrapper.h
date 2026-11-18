#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SDProgressBlock)(int step, int steps, float timeElapsed);
typedef void (^SDCompletionBlock)(NSString * _Nullable base64Png, NSString * _Nullable errorMsg);

@interface SDWrapper : NSObject

+ (instancetype)shared;
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
                        completion:(SDCompletionBlock)completionBlock;

- (void)cancelGeneration;

@end

NS_ASSUME_NONNULL_END
