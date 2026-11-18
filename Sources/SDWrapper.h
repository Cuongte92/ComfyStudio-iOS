#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SDWrapper : NSObject

+ (NSString *)modelsDirectoryPath;
+ (NSString *)outputsDirectoryPath;
+ (NSArray<NSString *> *)listAvailableModels;

+ (int)generateImageWithModelPath:(NSString *)modelPath
                           prompt:(NSString *)prompt
                   negativePrompt:(NSString *)negativePrompt
                       outputPath:(NSString *)outputPath
                            width:(int)width
                           height:(int)height
                            steps:(int)steps
                         cfgScale:(float)cfgScale
                             seed:(long long)seed
                          sampler:(NSString *)sampler;

@end

NS_ASSUME_NONNULL_END
