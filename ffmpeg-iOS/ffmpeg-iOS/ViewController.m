//
//  ViewController.m
//  ffmpeg-iOS
//
//  Created by jiang on 2025/9/19.
//

#import "ViewController.h"

#import "JVideoDecoder.h"

#define LOCAL_MIN_BUFFERED_DURATION   0.2
#define LOCAL_MAX_BUFFERED_DURATION   0.4
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0

static NSString * formatTimeInterval(CGFloat seconds, BOOL isLeft)
{
    seconds = MAX(0, seconds);
    
    NSInteger s = seconds;
    NSInteger m = s / 60;
    NSInteger h = m / 60;
    
    s = s % 60;
    m = m % 60;

    NSMutableString *format = [(isLeft && seconds >= 0.5 ? @"-" : @"") mutableCopy];
    if (h != 0) [format appendFormat:@"%d:%0.2d", h, m];
    else        [format appendFormat:@"%d", m];
    [format appendFormat:@":%0.2d", s];

    return format;
}

@interface ViewController ()
{
    BOOL _interrupted;
    dispatch_queue_t _dispatchQueue;
    NSMutableArray *_videoFrames;
    CGFloat _minBufferedDuration;
    CGFloat _maxBufferedDuration;
    CGFloat _bufferedDuration;
    BOOL _buffered;
    NSTimeInterval _tickCorrectionTime;
    NSTimeInterval _tickCorrectionPosition;
    CGFloat _moviePosition;
}

@property (nonatomic,strong) JVideoDecoder *decoder;
@property (nonatomic) BOOL decoding;
@property (readwrite) BOOL playing;
@property (nonatomic,strong) UIImageView *imageView;
@property (nonatomic,strong) UISlider *progressSlider;
@property (nonatomic,strong) UILabel *leftLabel;
@property (nonatomic,strong) UILabel *rightLabel;

@end
//https://www.w3school.com.cn/example/html5/mov_bbb.mp4
@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    self.view.backgroundColor = UIColor.blackColor;

    __weak ViewController *weakSelf = self;
    NSString *path = [[NSBundle mainBundle] pathForResource:@"test" ofType:@"MOV"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        [self.decoder openFile:path error:&error];
        if(error){return;}
        __strong ViewController *strongSelf = weakSelf;
        if (strongSelf){
            dispatch_sync(dispatch_get_main_queue(), ^{
                [strongSelf updateMovie];
                [strongSelf setupPresentView];
            });
        }
    });
//#if DEBUG
//    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(50, 50, 100, 100)];
//    view.backgroundColor = [UIColor redColor];
//    view.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
//    [self.view addSubview:view];
//    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
//        [self.view bringSubviewToFront:view];
//    });
//#endif
}

-(void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];
    self.imageView.frame = self.view.bounds;
    self.leftLabel.frame = CGRectMake(16, CGRectGetHeight(self.view.frame) - 50, 50, 19);
    self.rightLabel.frame = CGRectMake(CGRectGetWidth(self.view.frame) - 16 - 50, CGRectGetHeight(self.view.frame) - 50, 50, 19);
    self.progressSlider.frame = CGRectMake(16 + 50 + 19, CGRectGetHeight(self.view.frame) - 50, CGRectGetWidth(self.view.frame) - 16 - 50 - 19 - 16 - 50, 19);
}

-(void)updateMovie{
    _dispatchQueue  = dispatch_queue_create("Video", DISPATCH_QUEUE_SERIAL);
    _videoFrames = [NSMutableArray array];
    if (_decoder.isNetwork) {
        _minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
        _maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;
    } else {
        _minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
        _maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
    }
    [self play];
}

- (void)setupPresentView{
    [self.decoder setupVideoFrameFormat:VideoFrameFormatRGB];
    [self.view addSubview:self.imageView];
    [self.view addSubview:self.leftLabel];
    [self.view addSubview:self.progressSlider];
    [self.view addSubview:self.rightLabel];
}

-(void) updateHUD{
    const CGFloat duration = _decoder.duration;
    const CGFloat position = _moviePosition -_decoder.startTime;
    if (_progressSlider.state == UIControlStateNormal)
        _progressSlider.value = position / duration;
    _leftLabel.text = formatTimeInterval(position, NO);
    if (_decoder.duration != MAXFLOAT)
        _rightLabel.text = formatTimeInterval(duration - position, YES);
}

-(void)play{
    if (self.playing) return;
    if (!_decoder.validVideo) return;
    self.playing = YES;
    _interrupted = NO;
    _tickCorrectionTime = 0;
    [self asyncDecodeFrames];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self tick];
    });
}

-(void)tick{
    if (_buffered && ((_bufferedDuration > _minBufferedDuration) || _decoder.isEOF)) {
        _buffered = NO;
    }
    CGFloat interval = 0;
    if (!_buffered) interval = [self presentFrame];
    if (self.playing){
        const NSUInteger leftFrames =
        (_decoder.validVideo ? _videoFrames.count : 0);
        if (0 == leftFrames){
            if (_decoder.isEOF) {
                [self pause];
                [self updateHUD];
                return;
            }
            if (_minBufferedDuration > 0 && !_buffered) {
                _buffered = YES;
            }
        }
        if (!leftFrames || !(_bufferedDuration > _minBufferedDuration)) {
            [self asyncDecodeFrames];
        }
        
        const NSTimeInterval correction = [self tickCorrection];
        const NSTimeInterval time = MAX(interval + correction, 0.01);
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self tick];
        });
        
    }
    [self updateHUD];
}

- (void) pause
{
    if (!self.playing) return;
    self.playing = NO;
}

- (CGFloat) presentFrame{
    CGFloat interval = 0;
    if (_decoder.validVideo){
        VideoFrame *frame;
        @synchronized(_videoFrames) {
            
            if (_videoFrames.count > 0) {
                
                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }
        
        if (frame)
            interval = [self presentVideoFrame:frame];
    }
    
    return interval;
}

- (CGFloat) presentVideoFrame:(VideoFrame *)frame{
    _moviePosition = frame.position;
    VideoFrameRGB *rgbFrame = (VideoFrameRGB *)frame;
    _imageView.image = [rgbFrame asImage];
    return frame.duration;
}

- (void) asyncDecodeFrames{
    if (self.decoding) return;
    self.decoding = YES;
    __weak ViewController *weakSelf = self;
    __weak JVideoDecoder *weakDecoder = _decoder;
    const CGFloat duration = _decoder.isNetwork ? .0f : 0.1f;
    dispatch_async(_dispatchQueue, ^{
        __strong ViewController *strongSelf = weakSelf;
        if (!strongSelf.playing) return;
        BOOL good = YES;
        while (good)
        {
            good = NO;
            @autoreleasepool {
                __strong JVideoDecoder *decoder = weakDecoder;
                if (decoder && (decoder.validVideo)) {
                    NSArray *frames = [decoder decodeFrames:duration];
                    if (frames.count) {
                        __strong ViewController *strongSelf = weakSelf;
                        if (strongSelf)
                            good = [strongSelf addFrames:frames];
                    }
                }
            }
            __strong ViewController *strongSelf = weakSelf;
            if (strongSelf) strongSelf.decoding = NO;
        }
    });
}

- (BOOL)addFrames:(NSArray *)frames{
    if (_decoder.validVideo) {
        @synchronized(_videoFrames) {
            for (MovieFrame *frame in frames)
                if (frame.type == MovieFrameTypeVideo) {
                    [_videoFrames addObject:frame];
                    _bufferedDuration += frame.duration;
                }
        }
    }
    
    return self.playing && _bufferedDuration < _maxBufferedDuration;
}

- (CGFloat) tickCorrection
{
    if (_buffered) return 0;
    
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!_tickCorrectionTime) {
        _tickCorrectionTime = now;
        _tickCorrectionPosition = _moviePosition;
        return 0;
    }
    
    NSTimeInterval dPosition = _moviePosition - _tickCorrectionPosition;
    NSTimeInterval dTime = now - _tickCorrectionTime;
    NSTimeInterval correction = dPosition - dTime;
    
    if (correction > 1.f || correction < -1.f) {
        correction = 0;
        _tickCorrectionTime = 0;
    }
    return correction;
}

- (void)setMoviePosition:(CGFloat)position{
    self.playing = NO;
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        [self updatePosition:position playMode:YES];
    });
}

- (void) updatePosition:(CGFloat)position playMode: (BOOL) playMode{
    [self freeBufferedFrames];
    position = MIN(_decoder.duration - 1, MAX(0, position));
    __weak ViewController *weakSelf = self;
    dispatch_async(_dispatchQueue, ^{
        if(playMode){
            __strong ViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf setDecoderPosition: position];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong ViewController *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf play];
                }
            });
        }
        else{
            __strong ViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf setDecoderPosition: position];
            [strongSelf decodeFrames];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong ViewController *strongSelf = weakSelf;
                if (strongSelf) {
                    [strongSelf setMoviePositionFromDecoder];
                    [strongSelf presentFrame];
                    [strongSelf updateHUD];
                }
            });
            
        }
    });
}

- (void) freeBufferedFrames
{
    @synchronized(_videoFrames) {
        [_videoFrames removeAllObjects];
    }
    
    _bufferedDuration = 0;
}

- (void) setDecoderPosition:(CGFloat)position
{
    _decoder.position = position;
}

- (void)setMoviePositionFromDecoder
{
    _moviePosition = _decoder.position;
}

- (BOOL) decodeFrames
{
    NSArray *frames = nil;
    if (_decoder.validVideo) {
        frames = [_decoder decodeFrames:0];
    }
    
    if (frames.count) {
        return [self addFrames: frames];
    }
    return NO;
}

- (void)progressDidChange:(id)sender
{
    UISlider *slider = sender;
    [self setMoviePosition:slider.value * _decoder.duration];
}

#pragma mark - setter&getter
-(JVideoDecoder *)decoder{
    if(!_decoder){
        _decoder = [[JVideoDecoder alloc] init];
        __weak ViewController *weakSelf = self;
        _decoder.interruptCallback = ^BOOL(){
            __strong ViewController *strongSelf = weakSelf;
            return strongSelf ? [strongSelf interruptDecoder] : YES;
        };
    }
    return _decoder;
}

- (BOOL)interruptDecoder
{
    return _interrupted;
}

-(UIImageView *)imageView{
    if(!_imageView){
        _imageView = [[UIImageView alloc] init];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
    }
    return _imageView;
}

-(UISlider *)progressSlider{
    if(!_progressSlider){
        _progressSlider = [[UISlider alloc] init];
        _progressSlider.continuous = NO;
        _progressSlider.value = 0;
        [_progressSlider addTarget:self
                            action:@selector(progressDidChange:)
                  forControlEvents:UIControlEventValueChanged];
    }
    return _progressSlider;
}

-(UILabel *)leftLabel{
    if(!_leftLabel){
        _leftLabel = [[UILabel alloc] init];
        _leftLabel.textColor = [UIColor whiteColor];
    }
    return _leftLabel;
}

-(UILabel *)rightLabel{
    if(!_rightLabel){
        _rightLabel = [[UILabel alloc] init];
        _rightLabel.textColor = [UIColor whiteColor];
    }
    return _rightLabel;
}

@end
