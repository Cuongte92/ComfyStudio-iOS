#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^SDProgressBlock)(int step, int totalSteps, float elapsed);
typedef void (^SDCompletionBlock)(NSString * _Nullable base64Png, NSString * _Nullable errorMsg);
typedef void (^DTConnectCompletionBlock)(BOOL success, NSArray<NSString *> * _Nullable models, NSArray<NSString *> * _Nullable loras, NSString * _Nullable errorMsg);

@interface SDWrapper : NSObject

+ (instancetype)shared;

// Local A19 Pro Metal
- (void)cancelGeneration;
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
                        completion:(SDCompletionBlock)completionBlock;

// Draw Things gRPC Server (Colab / Pinggy / Modal)
- (void)connectDrawThingsGRPC:(NSString *)endpoint
                       useTLS:(BOOL)useTLS
                   completion:(DTConnectCompletionBlock)completion;

- (void)cancelDrawThingsGRPC;

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
                        completion:(SDCompletionBlock)completionBlock;

@end

NS_ASSUME_NONNULL_END
