//
//  JVideoDecoder.h
//  ffmpeg-iOS
//
//  Created by jiang on 2025/9/20.
//

#import <Foundation/Foundation.h>
#import<UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum : NSUInteger {
    MovieErrorNone,
    MovieErrorOpenFile,
    MovieErrorStreamInfoNotFound,
    MovieErrorStreamNotFound,
    MovieErrorCodecNotFound,
    MovieErrorOpenCodec,
    MovieErrorAllocateFrame
} MovieError;

typedef enum {
    MovieFrameTypeAudio,
    MovieFrameTypeVideo,
} MovieFrameType;

typedef enum {
    VideoFrameFormatRGB,
    VideoFrameFormatYUV,
} VideoFrameFormat;

@interface MovieFrame : NSObject
@property (readonly, nonatomic) MovieFrameType type;
@property (readonly, nonatomic) CGFloat position;
@property (readonly, nonatomic) CGFloat duration;
@end

@interface VideoFrame : MovieFrame
@property (readonly, nonatomic) VideoFrameFormat format;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
@end

@interface VideoFrameYUV : VideoFrame
@property (readonly, nonatomic, strong) NSData *luma;
@property (readonly, nonatomic, strong) NSData *chromaB;
@property (readonly, nonatomic, strong) NSData *chromaR;
@end

@interface VideoFrameRGB : VideoFrame
@property (readonly, nonatomic) NSUInteger linesize;
@property (readonly, nonatomic, strong) NSData *rgb;
- (UIImage *) asImage;
@end

typedef BOOL(^MovieDecoderInterruptCallback)(void);

@interface JVideoDecoder : NSObject

@property (nonatomic,readonly,strong) NSString *path;
@property (readonly, nonatomic) CGFloat fps;

- (BOOL)openFile:(NSString *)path
           error:(NSError **)error;

@property (readwrite, nonatomic, strong) MovieDecoderInterruptCallback interruptCallback;
@property (readonly, nonatomic) BOOL isNetwork;
@property (readonly, nonatomic) BOOL validVideo;
@property (readonly, nonatomic) BOOL isEOF;
@property (nonatomic) CGFloat position;
@property (readonly, nonatomic) CGFloat duration;
@property (readonly, nonatomic) CGFloat startTime;

- (BOOL) interruptDecoder;
- (NSArray *)decodeFrames:(CGFloat)minDuration;
- (BOOL) setupVideoFrameFormat: (VideoFrameFormat)format;

@end

NS_ASSUME_NONNULL_END
