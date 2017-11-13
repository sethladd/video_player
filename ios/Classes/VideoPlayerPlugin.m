#import <AVFoundation/AVFoundation.h>
#import "VideoPlayerPlugin.h"

@interface FrameUpdater : NSObject
@property(nonatomic) int64_t textureId;
@property(nonatomic, readonly) NSObject<FlutterTextureRegistry>* registry;
- (void)onDisplayLink:(CADisplayLink*)link;
@end

@implementation FrameUpdater
- (FrameUpdater*)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry {
  self = [super init];
  _registry = registry;
  return self;
}

- (void)onDisplayLink:(CADisplayLink*)link {
  [_registry textureFrameAvailable:_textureId];
}
@end

@interface VideoPlayer : NSObject<FlutterTexture>
@property(readonly, nonatomic) AVPlayer* player;
@property(readonly, nonatomic) AVPlayerItemVideoOutput* videoOutput;
@property(readonly, nonatomic) CADisplayLink* displayLink;
@property(nonatomic, copy) void (^onFrameAvailable)();
- (instancetype)initWithURL:(NSURL*)url
           withFrameUpdater:(FrameUpdater*)frameUpdater;
- (void)play;
- (void)pause;
@end

@implementation VideoPlayer
- (instancetype)initWithURL:(NSURL*)url
           withFrameUpdater:(FrameUpdater*)frameUpdater {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _player = [[AVPlayer alloc] init];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                                                    object:[_player currentItem]
                                                     queue:[NSOperationQueue mainQueue]
                                                usingBlock:^(NSNotification *note) {
    AVPlayerItem *p = [note object];
    [p seekToTime:kCMTimeZero];
  }];
  NSDictionary *pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
  };
  _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];
  AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
  AVAsset *asset = [item asset];
  [asset loadValuesAsynchronouslyForKeys:@[@"tracks"] completionHandler:^{
      if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
          NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
          if ([tracks count] > 0) {
              AVAssetTrack *videoTrack = [tracks objectAtIndex:0];
              [videoTrack loadValuesAsynchronouslyForKeys:@[@"preferredTransform"] completionHandler:^{
                if ([videoTrack statusOfValueForKey:@"preferredTransform" error:nil] == AVKeyValueStatusLoaded) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                          [item addOutput:_videoOutput];
                          [_player replaceCurrentItemWithPlayerItem:item];
                          [_player play];
                      });
                  }
              }];
          }
      }
  }];
  _displayLink = [CADisplayLink displayLinkWithTarget:frameUpdater selector:@selector(onDisplayLink:)];
  [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
  _displayLink.paused = YES;
  return self;
}

- (void)play {
  [_player play];
  _displayLink.paused = NO;
}

- (void)pause {
  [_player pause];
  _displayLink.paused = YES;
}

- (void)onDisplayLink:(CADisplayLink*)link {
  if (_onFrameAvailable) {
    _onFrameAvailable();
  }
}

- (CVPixelBufferRef)copyPixelBuffer {
  CMTime outputItemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
  if ([_videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
      return [_videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
  } else {
    return NULL;
  }
}
@end

@interface VideoPlayerPlugin ()
@property(readonly, nonatomic) NSObject<FlutterTextureRegistry>* registry;
@property(readonly, nonatomic) NSMutableDictionary* players;
@end

@implementation VideoPlayerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel = [FlutterMethodChannel
      methodChannelWithName:@"video_player"
            binaryMessenger:[registrar messenger]];
  VideoPlayerPlugin* instance = [[VideoPlayerPlugin alloc] initWithRegistry:[registrar textures]];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (instancetype)initWithRegistry:(NSObject<FlutterTextureRegistry>*)registry {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = registry;
  _players = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"create" isEqualToString:call.method]) {
    NSDictionary* argsMap = call.arguments;
    NSString* dataSource = argsMap[@"dataSource"];
    FrameUpdater* frameUpdater =
        [[FrameUpdater alloc] initWithRegistry:_registry];
    VideoPlayer* player =
        [[VideoPlayer alloc] initWithURL:[NSURL URLWithString:dataSource]
                        withFrameUpdater:frameUpdater];
    int64_t textureId = [_registry registerTexture:player];
    frameUpdater.textureId = textureId;
    _players[@(textureId)] = player;
    result(@(textureId));
  } else {
    NSDictionary* argsMap = call.arguments;
    NSUInteger textureId = ((NSNumber*) argsMap[@"textureId"]).unsignedIntegerValue;
    AVPlayer* player = _players[@(textureId)];
    if ([@"dispose" isEqualToString:call.method]) {
      [_players removeObjectForKey:@(textureId)];
      [_registry unregisterTexture:textureId];
    } else if ([@"play" isEqualToString:call.method]) {
      [player play];
    } else if ([@"pause" isEqualToString:call.method]) {
      [player pause];
    } else {
      result(FlutterMethodNotImplemented);
    }
  }
}

@end
