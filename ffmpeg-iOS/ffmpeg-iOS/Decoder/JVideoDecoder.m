//
//  JVideoDecoder.m
//  ffmpeg-iOS
//
//  Created by jiang on 2025/9/20.
//

#import "JVideoDecoder.h"

#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libswscale/swscale.h"
#include "libavutil/imgutils.h"

#import <CoreGraphics/CoreGraphics.h>


static BOOL isNetWorkPath(NSString *path){
    if([path isKindOfClass:[NSString class]] && ([path hasPrefix:@"http://"] || [path hasPrefix:@"https://"])){
        return YES;
    }else{
        return NO;
    }
}

static NSArray *collectStreams(AVFormatContext *formatCtx, enum AVMediaType codecType)
{
    NSMutableArray *arr = [NSMutableArray array];
    for (NSInteger i = 0; i < formatCtx->nb_streams; ++i)
        if (codecType == formatCtx->streams[i]->codecpar->codec_type)
            [arr addObject: [NSNumber numberWithInteger: i]];
    return [arr copy];
}

static int interrupt_callback(void *ctx)
{
    if (!ctx)
        return 0;
    __unsafe_unretained JVideoDecoder *p = (__bridge JVideoDecoder *)ctx;
    
    const BOOL r = [p interruptDecoder];
//    if (r) LoggerStream(1, @"DEBUG: INTERRUPT_CALLBACK!");
    return r;
}

static NSData * copyFrameData(UInt8 *src, int linesize, int width, int height)
{
    width = MIN(linesize, width);
    NSMutableData *md = [NSMutableData dataWithLength: width * height];
    Byte *dst = md.mutableBytes;
    for (NSUInteger i = 0; i < height; ++i) {
        memcpy(dst, src, width);
        dst += width;
        src += linesize;
    }
    return md;
}

static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase)
{
    CGFloat fps, timebase;

    if (st->time_base.den && st->time_base.num)
        timebase = av_q2d(st->time_base);
    else
        timebase = defaultTimeBase;
         
    if (st->avg_frame_rate.den && st->avg_frame_rate.num)
        fps = av_q2d(st->avg_frame_rate);
    else if (st->r_frame_rate.den && st->r_frame_rate.num)
        fps = av_q2d(st->r_frame_rate);
    else
        fps = 1.0 / timebase;
    
    if (pFPS)
        *pFPS = fps;
    if (pTimeBase)
        *pTimeBase = timebase;
}

@interface MovieFrame()
@property (readwrite, nonatomic) CGFloat position;
@property (readwrite, nonatomic) CGFloat duration;
@end

@implementation MovieFrame
@end

@interface VideoFrame()
@property (readwrite, nonatomic) NSUInteger width;
@property (readwrite, nonatomic) NSUInteger height;
@end

@implementation VideoFrame
- (MovieFrameType) type { return MovieFrameTypeVideo; }
@end

@interface VideoFrameYUV()
@property (readwrite, nonatomic, strong) NSData *luma;
@property (readwrite, nonatomic, strong) NSData *chromaB;
@property (readwrite, nonatomic, strong) NSData *chromaR;
@end
@implementation VideoFrameYUV
- (VideoFrameFormat) format { return VideoFrameFormatYUV; }
@end

@interface VideoFrameRGB ()
@property (readwrite, nonatomic) NSUInteger linesize;
@property (readwrite, nonatomic, strong) NSData *rgb;
@end

@implementation VideoFrameRGB
- (VideoFrameFormat) format { return VideoFrameFormatRGB; }
- (UIImage *) asImage
{
    UIImage *image = nil;
    
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)(_rgb));
    if (provider) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (colorSpace) {
            CGImageRef imageRef = CGImageCreate(self.width,
                                                self.height,
                                                8,
                                                24,
                                                self.linesize,
                                                colorSpace,
                                                kCGBitmapByteOrderDefault,
                                                provider,
                                                NULL,
                                                YES, // NO
                                                kCGRenderingIntentDefault);
            
            if (imageRef) {
                image = [UIImage imageWithCGImage:imageRef];
                CGImageRelease(imageRef);
            }
            CGColorSpaceRelease(colorSpace);
        }
        CGDataProviderRelease(provider);
    }
    
    return image;
}
@end

@interface JVideoDecoder (){
    AVFormatContext *_formatContext;
    AVCodecContext *_videoCodecCtx;
    NSInteger _videoStream;
    NSArray *_videoStreams;
    CGFloat _position;
    AVFrame *_videoFrame;
    VideoFrameFormat _videoFrameFormat;
    struct SwsContext *_swsContext;
    AVFrame *_picture;
    BOOL _pictureValid;
    CGFloat _videoTimeBase;
}


@end

@implementation JVideoDecoder

- (BOOL)openFile:(NSString *)path
           error:(NSError **)error{
    if(!path){
        NSLog(@"路径为空");
        return NO;
    }
    _isNetwork = isNetWorkPath(path);
    if(self.isNetwork){
        avformat_network_init();
    }
    _path = path;
    MovieError errCode = [self openInput: path];
    if (errCode == MovieErrorNone){
        MovieError videoErr = [self openVideoStream];
        if (videoErr != MovieErrorNone){
            errCode = videoErr;
        }
    }
    
    if (errCode != MovieErrorNone){
        [self closeFile];
        if (error){
            *error = [NSError errorWithDomain:@"video" code:errCode userInfo:nil];
        }
        return NO;
    }
    
    return MovieErrorNone;
}

-(void)closeFile{
    [self closeVideoStream];
    _videoStreams = nil;
    if (_formatContext) {
        
        _formatContext->interrupt_callback.opaque = NULL;
        _formatContext->interrupt_callback.callback = NULL;
        
        avformat_close_input(&_formatContext);
        _formatContext = NULL;
    }
}

- (void)closeVideoStream
{
    _videoStream = -1;
    
    if (_videoCodecCtx) {
        avcodec_close(_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
}

- (MovieError) openInput: (NSString *) path
{
    AVFormatContext *formatCtx = NULL;
    
    if (_interruptCallback) {
        formatCtx = avformat_alloc_context();
        if (!formatCtx) return MovieErrorOpenFile;
        AVIOInterruptCB cb = {interrupt_callback, (__bridge void *)(self)};
        formatCtx->interrupt_callback = cb;
    }
    
    if (avformat_open_input(&formatCtx, [path cStringUsingEncoding: NSUTF8StringEncoding], NULL, NULL) < 0) {
        if (formatCtx) avformat_free_context(formatCtx);
        return MovieErrorOpenFile;
    }
    
    if (avformat_find_stream_info(formatCtx, NULL) < 0) {
        avformat_close_input(&formatCtx);
        return MovieErrorStreamInfoNotFound;
    }

    av_dump_format(formatCtx, 0, [path.lastPathComponent cStringUsingEncoding: NSUTF8StringEncoding], false);
    
    _formatContext = formatCtx;
    return MovieErrorNone;
}

- (MovieError) openVideoStream{
    MovieError errCode = MovieErrorStreamNotFound;
    _videoStream = -1;
    _videoStreams = collectStreams(_formatContext, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        const NSUInteger iStream = n.integerValue;
        if (0 == (_formatContext->streams[iStream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            errCode = [self openVideoStream: iStream];
            if (errCode == MovieErrorNone)break;
        }
    }
    
    return errCode;
}

- (MovieError)openVideoStream: (NSInteger)videoStream{
    AVCodecParameters *codecpar = _formatContext->streams[videoStream]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(codecpar->codec_id);
    AVCodecContext *codec_ctx = avcodec_alloc_context3(codec);
    avcodec_parameters_to_context(codec_ctx, codecpar);
    AVCodecContext *codecCtx = codec_ctx;
    
    if (!codec) return MovieErrorCodecNotFound;
    if (avcodec_open2(codecCtx, codec, NULL) < 0) return MovieErrorOpenCodec;
    _videoFrame = av_frame_alloc();
    if (!_videoFrame) {
        avcodec_close(codecCtx);
        return MovieErrorAllocateFrame;
    }
    _videoStream = videoStream;
    _videoCodecCtx = codecCtx;
    
    AVStream *st = _formatContext->streams[_videoStream];
    avStreamFPSTimeBase(st, 0.04, &_fps, &_videoTimeBase);
    
    return MovieErrorNone;
}

- (NSArray *)decodeFrames:(CGFloat)minDuration{
    if (_videoStream == -1) return nil;
    NSMutableArray *result = [NSMutableArray array];
    CGFloat decodedDuration = 0;
    BOOL finished = NO;
    while (!finished){
        AVPacket *packet = av_packet_alloc();
        if (av_read_frame(_formatContext, packet) < 0) {
            _isEOF = YES;
            break;
        }
        
        if (packet->stream_index ==_videoStream) {
            int pktSize = packet->size;
            if (pktSize > 0) {
                if (avcodec_send_packet(_videoCodecCtx, packet) == 0){
                    while (avcodec_receive_frame(_videoCodecCtx, _videoFrame) == 0){
                        VideoFrame *frame = [self handleVideoFrame];
                        if (frame) {
                            [result addObject:frame];
                            _position = frame.position;
                            decodedDuration += frame.duration;
                            if (decodedDuration > minDuration)
                                finished = YES;
                        }
                    }
                }
            }
        }
    }
    return result;
}

- (BOOL)setupVideoFrameFormat: (VideoFrameFormat)format{
    if (format == VideoFrameFormatYUV &&
        _videoCodecCtx &&
        (_videoCodecCtx->pix_fmt == AV_PIX_FMT_YUV420P || _videoCodecCtx->pix_fmt == AV_PIX_FMT_YUVJ420P)) {
        
        _videoFrameFormat = VideoFrameFormatYUV;
        return YES;
    }
    
    _videoFrameFormat = VideoFrameFormatRGB;
    return _videoFrameFormat == format;
}

- (VideoFrame *) handleVideoFrame
{
    if (!_videoFrame->data[0])
        return nil;
    
    VideoFrame *frame;
    
    if (_videoFrameFormat == VideoFrameFormatYUV) {
            
        VideoFrameYUV * yuvFrame = [[VideoFrameYUV alloc] init];
        
        yuvFrame.luma = copyFrameData(_videoFrame->data[0],
                                      _videoFrame->linesize[0],
                                      _videoCodecCtx->width,
                                      _videoCodecCtx->height);
        
        yuvFrame.chromaB = copyFrameData(_videoFrame->data[1],
                                         _videoFrame->linesize[1],
                                         _videoCodecCtx->width / 2,
                                         _videoCodecCtx->height / 2);
        
        yuvFrame.chromaR = copyFrameData(_videoFrame->data[2],
                                         _videoFrame->linesize[2],
                                         _videoCodecCtx->width / 2,
                                         _videoCodecCtx->height / 2);
        
        frame = yuvFrame;
    
    } else {
    
        if (!_swsContext && ![self setupScaler]) {
            return nil;
        }
        
        sws_scale(_swsContext,
                  (const uint8_t **)_videoFrame->data,
                  _videoFrame->linesize,
                  0,
                  _videoCodecCtx->height,
                  _picture->data,
                  _picture->linesize);
        
        
        VideoFrameRGB *rgbFrame = [[VideoFrameRGB alloc] init];
        
        rgbFrame.linesize = _picture->linesize[0];
        rgbFrame.rgb = [NSData dataWithBytes:_picture->data[0]
                                    length:rgbFrame.linesize * _videoCodecCtx->height];
        frame = rgbFrame;
    }
    
    frame.width = _videoCodecCtx->width;
    frame.height = _videoCodecCtx->height;
    
    frame.position = _videoFrame->best_effort_timestamp * _videoTimeBase;
    
    const int64_t frameDuration = _videoFrame->duration;//av_frame_get_pkt_duration(_videoFrame);
    if (frameDuration) {
        
        frame.duration = frameDuration * _videoTimeBase;
        frame.duration += _videoFrame->repeat_pict * _videoTimeBase * 0.5;
        
        
    } else {
        
        // sometimes, ffmpeg unable to determine a frame duration
        // as example yuvj420p stream from web camera
        frame.duration = 1.0 / _fps;
    }
    
    return frame;
}

- (BOOL) setupScaler
{
    [self closeScaler];
    _picture = av_frame_alloc();
    if(!_picture){
        return NO;
    }
    _picture->format = AV_PIX_FMT_RGB24;
    _picture->width = _videoCodecCtx->width;
    _picture->height = _videoCodecCtx->height;
    _picture->pts = 0;
    int ret = av_image_alloc(_picture->data, _picture->linesize, _picture->width, _picture->height, _picture->format, 1);
    if(ret < 0){
        av_frame_free(&_picture);
        return NO;
    }
//    if (!_pictureValid)
//        return NO;

    _swsContext = sws_getCachedContext(_swsContext,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       _videoCodecCtx->pix_fmt,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       AV_PIX_FMT_RGB24,
                                       SWS_FAST_BILINEAR,
                                       NULL, NULL, NULL);
        
    return _swsContext != NULL;
}

- (void) closeScaler
{
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    
    if (_pictureValid) {
        av_frame_free(&_picture);
        _pictureValid = NO;
    }
}

- (BOOL) interruptDecoder
{
    if (_interruptCallback)
        return _interruptCallback();
    return NO;
}

- (BOOL) validVideo
{
    return _videoStream != -1;
}

- (void)setPosition:(CGFloat)seconds
{
    _position = seconds;
    _isEOF = NO;
       
    if (_videoStream != -1) {
        int64_t ts = (int64_t)(seconds / _videoTimeBase);
        avformat_seek_file(_formatContext, _videoStream, ts, ts, ts, AVSEEK_FLAG_FRAME);
        avcodec_flush_buffers(_videoCodecCtx);
    }
}

- (CGFloat) duration
{
    if (!_formatContext)
        return 0;
    if (_formatContext->duration == AV_NOPTS_VALUE)
        return MAXFLOAT;
    return (CGFloat)_formatContext->duration / AV_TIME_BASE;
}

- (CGFloat) startTime
{
    if (_videoStream != -1) {
        AVStream *st = _formatContext->streams[_videoStream];
        if (AV_NOPTS_VALUE != st->start_time)
            return st->start_time * _videoTimeBase;
        return 0;
    }
    return 0;
}

@end
