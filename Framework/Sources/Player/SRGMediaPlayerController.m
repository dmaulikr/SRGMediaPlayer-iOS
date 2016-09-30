//
//  Copyright (c) SRG. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGMediaPlayerController.h"

#import "NSBundle+SRGMediaPlayer.h"
#import "SRGMediaPlayerError.h"
#import "SRGMediaPlayerView.h"
#import "SRGPeriodicTimeObserver.h"
#import "SRGActivityGestureRecognizer.h"
#import "SRGLogger.h"

#import <libextobjc/EXTScope.h>
#import <objc/runtime.h>

static const NSTimeInterval SRGSegmentSeekToleranceInSeconds = 0.1;

static void *s_kvoContext = &s_kvoContext;

static NSError *SRGMediaPlayerControllerError(NSError *underlyingError);
static NSString *SRGMediaPlayerControllerNameForPlaybackState(SRGMediaPlayerPlaybackState playbackState);
static NSString *SRGMediaPlayerControllerNameForMediaType(SRGMediaPlayerMediaType mediaType);
static NSString *SRGMediaPlayerControllerNameForStreamType(SRGMediaPlayerStreamType streamType);

@interface SRGMediaPlayerController () {
@private
    SRGMediaPlayerPlaybackState _playbackState;
    BOOL _selected;
}

@property (nonatomic) NSURL *contentURL;
@property (nonatomic) NSArray<id<SRGSegment>> *segments;
@property (nonatomic) NSDictionary *userInfo;

@property (nonatomic) NSArray<id<SRGSegment>> *visibleSegments;

@property (nonatomic) NSMutableDictionary<NSString *, SRGPeriodicTimeObserver *> *periodicTimeObservers;
@property (nonatomic) id segmentPeriodicTimeObserver;

@property (nonatomic, weak) id<SRGSegment> previousSegment;
@property (nonatomic, weak) id<SRGSegment> targetSegment;
@property (nonatomic, weak) id<SRGSegment> currentSegment;

@property (nonatomic) AVPictureInPictureController *pictureInPictureController;

@property (nonatomic) NSValue *startTimeValue;
@property (nonatomic, copy) void (^startCompletionHandler)(void);

@end

@implementation SRGMediaPlayerController

@synthesize view = _view;
@synthesize pictureInPictureController = _pictureInPictureController;

#pragma mark Object lifecycle

- (instancetype)init
{
    if (self = [super init]) {
        _playbackState = SRGMediaPlayerPlaybackStateIdle;
        
        self.liveTolerance = SRGMediaPlayerLiveDefaultTolerance;
        self.periodicTimeObservers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc
{
    // No need to call -reset here, since -stop or -reset must be called for the controller to be deallocated
    self.pictureInPictureController = nil;              // Unregister KVO
}

#pragma mark Getters and setters

- (void)setPlayer:(AVPlayer *)player
{
    AVPlayer *previousPlayer = self.playerLayer.player;
    if (previousPlayer) {
        [self unregisterTimeObservers];
        
        [previousPlayer removeObserver:self forKeyPath:@"currentItem.status" context:s_kvoContext];
        [previousPlayer removeObserver:self forKeyPath:@"rate" context:s_kvoContext];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemPlaybackStalledNotification
                                                      object:previousPlayer.currentItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:previousPlayer.currentItem];
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                      object:previousPlayer.currentItem];
        
        self.playerDestructionBlock ? self.playerDestructionBlock(previousPlayer) : nil;
    }
    
    self.playerLayer.player = player;
    
    if (player) {
        [self registerTimeObserversForPlayer:player];
        
        [player addObserver:self
                 forKeyPath:@"currentItem.status"
                    options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                    context:s_kvoContext];
        [player addObserver:self
                 forKeyPath:@"rate"
                    options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld
                    context:s_kvoContext];
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(srg_mediaPlayerController_playerItemPlaybackStalled:)
                                                     name:AVPlayerItemPlaybackStalledNotification
                                                   object:player.currentItem];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(srg_mediaPlayerController_playerItemDidPlayToEndTime:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:player.currentItem];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(srg_mediaPlayerController_playerItemFailedToPlayToEndTime:)
                                                     name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                   object:player.currentItem];
        
        self.playerCreationBlock ? self.playerCreationBlock(player) : nil;
        self.playerConfigurationBlock ? self.playerConfigurationBlock(player) : nil;
    }
}

- (AVPlayer *)player
{
    return self.playerLayer.player;
}

- (AVPlayerLayer *)playerLayer
{
    return (AVPlayerLayer *)self.view.layer;
}

- (void)setPlaybackState:(SRGMediaPlayerPlaybackState)playbackState withUserInfo:(NSDictionary *)userInfo
{
    NSAssert([NSThread isMainThread], @"Not the main thread. Ensure important changes must be notified on the main thread. Fix");
    
    if (_playbackState == playbackState) {
        return;
    }
    
    NSMutableDictionary *fullUserInfo = [@{ SRGMediaPlayerPlaybackStateKey : @(playbackState),
                                            SRGMediaPlayerPreviousPlaybackStateKey: @(_playbackState) } mutableCopy];
    fullUserInfo[SRGMediaPlayerSelectionKey] = @(self.targetSegment && ! self.targetSegment.srg_blocked);
    if (userInfo) {
        [fullUserInfo addEntriesFromDictionary:userInfo];
    }
    
    [self willChangeValueForKey:@"playbackState"];
    _playbackState = playbackState;
    [self didChangeValueForKey:@"playbackState"];
    
    // Ensure segment status is up to date
    [self updateSegmentStatusForPlaybackState:playbackState time:self.player.currentTime];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                        object:self
                                                      userInfo:[fullUserInfo copy]];
}

- (void)setSegments:(NSArray<id<SRGSegment>> *)segments
{
    _segments = segments;
    
    // Reset the cached visible segment list
    _visibleSegments = nil;
}

- (NSArray<id<SRGSegment>> *)visibleSegments
{
    // Cached for faster access
    if (! _visibleSegments) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"srg_hidden == NO"];
        _visibleSegments = [self.segments filteredArrayUsingPredicate:predicate];
    }
    return _visibleSegments;
}

- (UIView *)view
{
    if (! _view) {
        _view = [[SRGMediaPlayerView alloc] init];
    }
    return _view;
}

- (CMTimeRange)timeRange
{
    AVPlayerItem *playerItem = self.player.currentItem;
    
    NSValue *firstSeekableTimeRangeValue = [playerItem.seekableTimeRanges firstObject];
    if (! firstSeekableTimeRangeValue) {
        return kCMTimeRangeInvalid;
    }
    
    NSValue *lastSeekableTimeRangeValue = [playerItem.seekableTimeRanges lastObject];
    if (! lastSeekableTimeRangeValue) {
        return kCMTimeRangeInvalid;
    }
    
    CMTimeRange firstSeekableTimeRange = [firstSeekableTimeRangeValue CMTimeRangeValue];
    CMTimeRange lastSeekableTimeRange = [lastSeekableTimeRangeValue CMTimeRangeValue];
    
    if (! CMTIMERANGE_IS_VALID(firstSeekableTimeRange) || ! CMTIMERANGE_IS_VALID(lastSeekableTimeRange)) {
        return kCMTimeRangeInvalid;
    }
    
    CMTimeRange timeRange = CMTimeRangeFromTimeToTime(firstSeekableTimeRange.start, CMTimeRangeGetEnd(lastSeekableTimeRange));
    
    // DVR window size too small. Check that we the stream is not an on-demand one first, of course
    if (CMTIME_IS_INDEFINITE(playerItem.duration) && CMTimeGetSeconds(timeRange.duration) < self.minimumDVRWindowLength) {
        return CMTimeRangeMake(timeRange.start, kCMTimeZero);
    }
    else {
        return timeRange;
    }
}

- (SRGMediaPlayerMediaType)mediaType
{
    if (! self.player) {
        return SRGMediaPlayerMediaTypeUnknown;
    }
    
    NSArray *tracks = self.player.currentItem.tracks;
    if (tracks.count == 0) {
        return SRGMediaPlayerMediaTypeUnknown;
    }
    
    NSString *mediaType = [[tracks.firstObject assetTrack] mediaType];
    return [mediaType isEqualToString:AVMediaTypeVideo] ? SRGMediaPlayerMediaTypeVideo : SRGMediaPlayerMediaTypeAudio;
}

- (SRGMediaPlayerStreamType)streamType
{
    CMTimeRange timeRange = self.timeRange;
    
    if (CMTIMERANGE_IS_INVALID(timeRange)) {
        return SRGMediaPlayerStreamTypeUnknown;
    }
    else if (CMTIMERANGE_IS_EMPTY(timeRange)) {
        return SRGMediaPlayerStreamTypeLive;
    }
    else if (CMTIME_IS_INDEFINITE(self.player.currentItem.duration)) {
        return SRGMediaPlayerStreamTypeDVR;
    }
    else {
        return SRGMediaPlayerStreamTypeOnDemand;
    }
}

- (void)setMinimumDVRWindowLength:(NSTimeInterval)minimumDVRWindowLength
{
    if (minimumDVRWindowLength < 0.) {
        SRGLogWarning(@"The minimum DVR window length cannot be negative. Set to 0");
        _minimumDVRWindowLength = 0.;
    }
    else {
        _minimumDVRWindowLength = minimumDVRWindowLength;
    }
}

- (void)setLiveTolerance:(NSTimeInterval)liveTolerance
{
    if (liveTolerance < 0.) {
        SRGLogWarning(@"Live tolerance cannot be negative. Set to 0");
        _liveTolerance = 0.;
    }
    else {
        _liveTolerance = liveTolerance;
    }
}

- (BOOL)isLive
{
    AVPlayerItem *playerItem = self.player.currentItem;
    if (! playerItem) {
        return NO;
    }
    
    if (self.streamType == SRGMediaPlayerStreamTypeLive) {
        return YES;
    }
    else if (self.streamType == SRGMediaPlayerStreamTypeDVR) {
        return CMTimeGetSeconds(CMTimeSubtract(CMTimeRangeGetEnd(self.timeRange), playerItem.currentTime)) < self.liveTolerance;
    }
    else {
        return NO;
    }
}

- (AVPictureInPictureController *)pictureInPictureController
{
    // It is especially important to wait until the player layer is ready for display, otherwise the player might behave
    // incorrectly (not correctly pause when asked to) because of the picture in picture controller, even if not active.
    // Weird, but it seems the relationship between both is tight, see
    //   https://developer.apple.com/library/ios/documentation/WindowsViews/Conceptual/AdoptingMultitaskingOniPad/QuickStartForPictureInPicture.html)
    if (! _pictureInPictureController && self.playerLayer.readyForDisplay) {
        // Call the setter for KVO registration
        self.pictureInPictureController = [[AVPictureInPictureController alloc] initWithPlayerLayer:self.playerLayer];
    }
    return _pictureInPictureController;
}

- (void)setPictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
{
    if (_pictureInPictureController) {
        [_pictureInPictureController removeObserver:self forKeyPath:@"pictureInPicturePossible" context:s_kvoContext];
        [_pictureInPictureController removeObserver:self forKeyPath:@"pictureInPictureActive" context:s_kvoContext];
    }
    
    _pictureInPictureController = pictureInPictureController;
    
    if (pictureInPictureController) {
        [pictureInPictureController addObserver:self forKeyPath:@"pictureInPicturePossible" options:NSKeyValueObservingOptionNew context:s_kvoContext];
        [pictureInPictureController addObserver:self forKeyPath:@"pictureInPictureActive" options:NSKeyValueObservingOptionNew context:s_kvoContext];
    }
}

#pragma mark Playback

- (void)prepareToPlayURL:(NSURL *)URL
                  atTime:(CMTime)time
            withSegments:(NSArray<id<SRGSegment>> *)segments
                userInfo:(NSDictionary *)userInfo
       completionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURL:URL atTime:time withSegments:segments targetSegment:nil userInfo:userInfo completionHandler:completionHandler];
}

- (void)play
{
    [self.player play];
}

- (void)pause
{
    [self.player pause];
}

- (void)stop
{
    [self stopWithUserInfo:nil];
}

- (void)seekToTime:(CMTime)time
withToleranceBefore:(CMTime)toleranceBefore
    toleranceAfter:(CMTime)toleranceAfter
 completionHandler:(void (^)(BOOL))completionHandler
{
    [self seekToTime:time withToleranceBefore:toleranceBefore toleranceAfter:toleranceAfter targetSegment:nil completionHandler:completionHandler];
}

- (void)reset
{
    // Save previous state information
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (self.contentURL) {
        userInfo[SRGMediaPlayerPreviousContentURLKey] = self.contentURL;
    }
    if (self.userInfo) {
        userInfo[SRGMediaPlayerPreviousUserInfoKey] = self.userInfo;
    }
    
    // Reset player state before stopping (so that any state change notification reflects this new state)
    self.contentURL = nil;
    self.segments = nil;
    self.userInfo = nil;
    
    [self stopWithUserInfo:[userInfo copy]];
}

#pragma mark Playback (convenience methods)

- (void)prepareToPlayURL:(NSURL *)URL withCompletionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURL:URL atTime:kCMTimeZero withSegments:nil userInfo:nil completionHandler:completionHandler];
}

- (void)playURL:(NSURL *)URL atTime:(CMTime)time withSegments:(NSArray<id<SRGSegment>> *)segments userInfo:(NSDictionary *)userInfo
{
    [self prepareToPlayURL:URL atTime:time withSegments:segments userInfo:userInfo completionHandler:^{
        [self play];
    }];
}

- (void)playURL:(NSURL *)URL
{
    [self playURL:URL atTime:kCMTimeZero withSegments:nil userInfo:nil];
}

- (void)togglePlayPause
{
    if (self.player.rate == 0.f) {
        [self.player play];
    }
    else {
        [self.player pause];
    }
}

- (void)seekEfficientlyToTime:(CMTime)time withCompletionHandler:(void (^)(BOOL))completionHandler
{
    [self seekToTime:time withToleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:completionHandler];
}

- (void)seekPreciselyToTime:(CMTime)time withCompletionHandler:(void (^)(BOOL))completionHandler
{
    [self seekToTime:time withToleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:completionHandler];
}

#pragma mark Segment playback

- (void)prepareToPlayURL:(NSURL *)URL
                 atIndex:(NSInteger)index
              inSegments:(NSArray<id<SRGSegment>> *)segments
            withUserInfo:(NSDictionary *)userInfo
       completionHandler:(void (^)(void))completionHandler
{
    // Incorrect index. Start at the default location
    if (index < 0 || index >= segments.count) {
        [self prepareToPlayURL:URL atTime:kCMTimeZero withSegments:segments targetSegment:nil userInfo:userInfo completionHandler:completionHandler];
    }
    else {
        [self prepareToPlayURL:URL atTime:kCMTimeZero withSegments:segments targetSegment:segments[index] userInfo:userInfo completionHandler:completionHandler];
    }
}

- (void)playURL:(NSURL *)URL atIndex:(NSInteger)index inSegments:(NSArray<id<SRGSegment>> *)segments withUserInfo:(NSDictionary *)userInfo
{
    [self prepareToPlayURL:URL atIndex:index inSegments:segments withUserInfo:userInfo completionHandler:^{
        [self play];
    }];
}

- (void)seekToSegmentAtIndex:(NSInteger)index withCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    if (index < 0 || index >= self.segments.count) {
        return;
    }
    
    [self seekToSegment:self.segments[index] withCompletionHandler:completionHandler];
}

- (void)seekToSegment:(id<SRGSegment>)segment withCompletionHandler:(void (^)(BOOL))completionHandler
{
    if (! [self.segments containsObject:segment]) {
        return;
    }
    
    // Do not seek to the very beginning, seek slightly after with zero tolerance to be sure to end within the segment
    [self seekToTime:CMTimeAdd(segment.srg_timeRange.start, CMTimeMakeWithSeconds(SRGSegmentSeekToleranceInSeconds, NSEC_PER_SEC))
 withToleranceBefore:kCMTimeZero
      toleranceAfter:kCMTimeZero
       targetSegment:segment
   completionHandler:completionHandler];
}

- (id<SRGSegment>)selectedSegment
{
    return _selected ? self.currentSegment : nil;
}

#pragma mark Playback (internal). Time parameters are ignored when valid segments are provided

- (void)prepareToPlayURL:(NSURL *)URL
                  atTime:(CMTime)time
            withSegments:(NSArray<id<SRGSegment>> *)segments
           targetSegment:(id<SRGSegment>)targetSegment
                userInfo:(NSDictionary *)userInfo
       completionHandler:(void (^)(void))completionHandler
{
    NSAssert(! targetSegment || [segments containsObject:targetSegment], @"Segment must be valid");
    
    if (targetSegment) {
        // Do not seek to the very beginning, seek slightly after with zero tolerance to be sure to end within the segment
        time = CMTimeAdd(targetSegment.srg_timeRange.start, CMTimeMakeWithSeconds(SRGSegmentSeekToleranceInSeconds, NSEC_PER_SEC));
    }
    else if (! CMTIME_IS_VALID(time)) {
        time = kCMTimeZero;
    }
    
    [self reset];
    
    self.contentURL = URL;
    self.segments = segments;
    self.userInfo = userInfo;
    self.targetSegment = targetSegment;
    
    [self setPlaybackState:SRGMediaPlayerPlaybackStatePreparing withUserInfo:nil];
    
    self.startTimeValue = [NSValue valueWithCMTime:time];
    self.startCompletionHandler = completionHandler;
    
    AVPlayerItem *playerItem = [[AVPlayerItem alloc] initWithURL:URL];
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
}

- (void)seekToTime:(CMTime)time
withToleranceBefore:(CMTime)toleranceBefore
    toleranceAfter:(CMTime)toleranceAfter
     targetSegment:(id<SRGSegment>)targetSegment
 completionHandler:(void (^)(BOOL))completionHandler
{
    NSAssert(! targetSegment || [self.segments containsObject:targetSegment], @"Segment must be valid");
    
    if (CMTIME_IS_INVALID(time) || self.player.currentItem.status != AVPlayerItemStatusReadyToPlay) {
        return;
    }
    
    self.targetSegment = targetSegment;
    
    // Trap attempts to seek to blocked segments early. We cannot only rely on playback time observers to detect a blocked segment
    // for direct seeks, otherwise blocked segment detection would occur after the segment has been entered, which is too late
    id<SRGSegment> segment = targetSegment ?: [self segmentForTime:time];
    if (! segment || ! segment.srg_blocked) {
        [self setPlaybackState:SRGMediaPlayerPlaybackStateSeeking withUserInfo:nil];
        [self.player seekToTime:time toleranceBefore:toleranceBefore toleranceAfter:toleranceAfter completionHandler:^(BOOL finished) {
            if (finished) {
                [self setPlaybackState:(self.player.rate == 0.f) ? SRGMediaPlayerPlaybackStatePaused : SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
            }
            completionHandler ? completionHandler(finished) : nil;
        }];
    }
    else {
        [self skipBlockedSegment:segment withCompletionHandler:completionHandler];
    }
}

- (void)stopWithUserInfo:(NSDictionary *)userInfo
{
    if (self.pictureInPictureController.isPictureInPictureActive) {
        [self.pictureInPictureController stopPictureInPicture];
    }
    
    [self setPlaybackState:SRGMediaPlayerPlaybackStateIdle withUserInfo:userInfo];
    
    self.previousSegment = nil;
    self.targetSegment = nil;
    self.currentSegment = nil;
    
    self.startTimeValue = nil;
    self.startCompletionHandler = nil;
    
    self.player = nil;
}

#pragma mark Configuration

- (void)reloadPlayerConfiguration
{
    if (self.player) {
        self.playerConfigurationBlock ? self.playerConfigurationBlock(self.player) : nil;
    }
}

#pragma mark Segments

- (void)updateSegmentStatusForPlaybackState:(SRGMediaPlayerPlaybackState)playbackState time:(CMTime)time
{
    if (CMTIME_IS_INVALID(time)) {
        return;
    }
    
    // Only update when relevant
    if (playbackState != SRGMediaPlayerPlaybackStatePaused && playbackState != SRGMediaPlayerPlaybackStatePlaying) {
        return;
    }
    
    if (self.targetSegment) {
        [self processTransitionToSegment:self.targetSegment selected:YES];
        self.targetSegment = nil;
    }
    else {
        id<SRGSegment> segment = [self segmentForTime:time];
        [self processTransitionToSegment:segment selected:NO];
    }
}

// Emit correct notifications for transitions (selected = NO for normal playback, YES if the segment has been selected)
// and seek over blocked segments
- (void)processTransitionToSegment:(id<SRGSegment>)segment selected:(BOOL)selected
{
    // No segment transition. Nothing to do
    if (segment == self.previousSegment && ! selected) {
        return;
    }
    
    if (self.previousSegment && ! self.previousSegment.srg_blocked) {
        self.currentSegment = nil;
        
        NSMutableDictionary *userInfo = [@{ SRGMediaPlayerSegmentKey : self.previousSegment,
                                            SRGMediaPlayerSelectionKey : @(selected),
                                            SRGMediaPlayerSelectedKey : @(_selected) } mutableCopy];
        if (! segment.srg_blocked) {
            userInfo[SRGMediaPlayerNextSegmentKey] = segment;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerSegmentDidEndNotification
                                                            object:self
                                                          userInfo:[userInfo copy]];
        _selected = NO;
    }
    
    if (segment) {
        if (! segment.srg_blocked) {
            _selected = selected;
            
            self.currentSegment = segment;
            
            NSMutableDictionary *userInfo = [@{ SRGMediaPlayerSegmentKey : segment,
                                                SRGMediaPlayerSelectionKey : @(_selected),
                                                SRGMediaPlayerSelectedKey : @(_selected) } mutableCopy];
            if (self.previousSegment && ! self.previousSegment.srg_blocked) {
                userInfo[SRGMediaPlayerPreviousSegmentKey] = self.previousSegment;
            }
            [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerSegmentDidStartNotification
                                                                object:self
                                                              userInfo:[userInfo copy]];
        }
        else {
            [self skipBlockedSegment:segment withCompletionHandler:nil];
        }
    }
    
    self.previousSegment = segment;
}

- (id<SRGSegment>)segmentForTime:(CMTime)time
{
    if (CMTIME_IS_INVALID(time)) {
        return nil;
    }
    
    __block id<SRGSegment> locatedSegment = nil;
    [self.segments enumerateObjectsUsingBlock:^(id<SRGSegment>  _Nonnull segment, NSUInteger idx, BOOL * _Nonnull stop) {
        if (CMTimeRangeContainsTime(segment.srg_timeRange, time)) {
            locatedSegment = segment;
            *stop = YES;
        }
    }];
    return locatedSegment;
}

// No tolerance parameters here. When skipping blocked segments, we want to resume sharply at segment end
- (void)skipBlockedSegment:(id<SRGSegment>)segment withCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    NSAssert(segment.srg_blocked, @"Expect a blocked segment");
    
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerWillSkipBlockedSegmentNotification
                                                        object:self
                                                      userInfo:@{ SRGMediaPlayerSegmentKey : segment }];
    
    // Seek precisely just after the end of the segment to avoid reentering the blocked segment when playback resumes (which
    // would trigger skips recursively)
    [self seekToTime:CMTimeAdd(CMTimeRangeGetEnd(segment.srg_timeRange), CMTimeMakeWithSeconds(SRGSegmentSeekToleranceInSeconds, NSEC_PER_SEC))
 withToleranceBefore:kCMTimeZero
      toleranceAfter:kCMTimeZero
   completionHandler:^(BOOL finished) {
        // Do not check the finished boolean. We want to emit the notification even if the seek is interrupted by another
        // one (e.g. due to a contiguous blocked segment being skipped). Emit the notification after the completion handler
        // so that consecutive notifications are received in the correct order
        [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerDidSkipBlockedSegmentNotification
                                                            object:self
                                                          userInfo:@{ SRGMediaPlayerSegmentKey : segment }];
        
        completionHandler ? completionHandler(finished) : nil;
    }];
}

#pragma mark Time observers

- (void)registerTimeObserversForPlayer:(AVPlayer *)player
{
    for (SRGPeriodicTimeObserver *playbackBlockRegistration in [self.periodicTimeObservers allValues]) {
        [playbackBlockRegistration attachToMediaPlayer:player];
    }
    
    @weakify(self)
    self.segmentPeriodicTimeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC) queue:NULL usingBlock:^(CMTime time) {
        @strongify(self)
        [self updateSegmentStatusForPlaybackState:self.playbackState time:time ];
    }];
}

- (void)unregisterTimeObservers
{
    [self.player removeTimeObserver:self.segmentPeriodicTimeObserver];
    self.segmentPeriodicTimeObserver = nil;
    
    for (SRGPeriodicTimeObserver *periodicTimeObserver in [self.periodicTimeObservers allValues]) {
        [periodicTimeObserver detachFromMediaPlayer];
    }
}

- (id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime time))block
{
    if (! block) {
        return nil;
    }
    
    NSString *identifier = [[NSUUID UUID] UUIDString];
    SRGPeriodicTimeObserver *periodicTimeObserver = [self periodicTimeObserverForInterval:interval queue:queue];
    [periodicTimeObserver setBlock:block forIdentifier:identifier];
    
    if (self.player) {
        [periodicTimeObserver attachToMediaPlayer:self.player];
    }
    
    // Return the opaque identifier
    return identifier;
}

- (void)removePeriodicTimeObserver:(id)observer
{
    for (NSString *key in self.periodicTimeObservers.allKeys) {
        SRGPeriodicTimeObserver *periodicTimeObserver = self.periodicTimeObservers[key];
        if (! [periodicTimeObserver hasBlockWithIdentifier:observer]) {
            continue;
        }
            
        [periodicTimeObserver removeBlockWithIdentifier:observer];
        
        // Remove the periodic time observer if not used anymore
        if (periodicTimeObserver.registrationCount == 0) {
            [self.periodicTimeObservers removeObjectForKey:key];
            return;
        }
    }
}

- (SRGPeriodicTimeObserver *)periodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue
{
    NSString *key = [NSString stringWithFormat:@"%@-%@-%@-%@-%p", @(interval.value), @(interval.timescale), @(interval.flags), @(interval.epoch), queue];
    SRGPeriodicTimeObserver *periodicTimeObserver = self.periodicTimeObservers[key];
    
    if (! periodicTimeObserver) {
        periodicTimeObserver = [[SRGPeriodicTimeObserver alloc] initWithInterval:interval queue:queue];
        self.periodicTimeObservers[key] = periodicTimeObserver;
    }
    
    return periodicTimeObserver;
}

#pragma mark Notifications

- (void)srg_mediaPlayerController_playerItemPlaybackStalled:(NSNotification *)notification
{
    [self setPlaybackState:SRGMediaPlayerPlaybackStateStalled withUserInfo:nil];
}

- (void)srg_mediaPlayerController_playerItemDidPlayToEndTime:(NSNotification *)notification
{
    [self setPlaybackState:SRGMediaPlayerPlaybackStateEnded withUserInfo:nil];
}

- (void)srg_mediaPlayerController_playerItemFailedToPlayToEndTime:(NSNotification *)notification
{
    self.startTimeValue = nil;
    self.startCompletionHandler = nil;
    
    [self setPlaybackState:SRGMediaPlayerPlaybackStateIdle withUserInfo:nil];
    
    NSError *error = SRGMediaPlayerControllerError(notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]);
    [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerPlaybackDidFailNotification
                                                        object:self
                                                      userInfo:@{ SRGMediaPlayerErrorKey: error }];
}

#pragma mark KVO

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    if ([key isEqualToString:@"playbackState"]) {
        return NO;
    }
    else {
        return [super automaticallyNotifiesObserversForKey:key];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *, id> *)change context:(void *)context
{
    NSAssert([NSThread isMainThread], @"Not the main thread. Ensure important changes must be notified on the main thread. Fix");
    
    if (context == s_kvoContext) {
        // If the rate or the item status changes, calculate the new playback status
        if ([keyPath isEqualToString:@"currentItem.status"] || [keyPath isEqualToString:@"rate"]) {
            AVPlayerItem *playerItem = self.player.currentItem;
            
            // Do not let playback pause when the player stalls, attempt to play again
            if (self.player.rate == 0.f && self.playbackState == SRGMediaPlayerPlaybackStateStalled) {
                [self.player play];
            }
            else if (playerItem.status == AVPlayerItemStatusReadyToPlay) {
                // Playback start. Use received start parameters, do not update the playback state yet, wait until the
                // completion handler has been executed (since it might immediately start playback)
                if (self.startTimeValue) {
                    void (^completionBlock)(BOOL) = ^(BOOL finished) {
                        // Reset start time first so that playback state induced change made in the completion handler
                        // does not loop back here
                        self.startTimeValue = nil;
                        
                        self.startCompletionHandler ? self.startCompletionHandler() : nil;
                        self.startCompletionHandler = nil;
                        
                        // If the state of the player was not changed in the completion handler (still preparing), update
                        // it
                        if (self.playbackState == SRGMediaPlayerPlaybackStatePreparing) {
                            [self setPlaybackState:(self.player.rate == 0.f) ? SRGMediaPlayerPlaybackStatePaused : SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
                        }
                    };
                    
                    CMTime startTime = self.startTimeValue.CMTimeValue;
                    
                    if (CMTIME_COMPARE_INLINE(startTime, ==, kCMTimeZero)) {
                        completionBlock(YES);
                    }
                    else {
                        // Call system method to avoid unwanted seek state in this special case
                        [self.player seekToTime:startTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero completionHandler:^(BOOL finished) {
                            completionBlock(finished);
                        }];
                    }
                }
                // Update the playback state immediately, except when reaching the end. Non-streamed medias will namely reach the paused state right before
                // the item end notification is received. We can eliminate this pause by checking if we are at the end or not. Also update the state for
                // live streams (empty range)
                else if (CMTIMERANGE_IS_EMPTY(self.timeRange) || CMTIME_COMPARE_INLINE(playerItem.currentTime, !=, CMTimeRangeGetEnd(self.timeRange))) {
                    [self setPlaybackState:(self.player.rate == 0.f) ? SRGMediaPlayerPlaybackStatePaused : SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
                }
            }
            else {
                if (playerItem.status == AVPlayerItemStatusFailed) {
                    [self setPlaybackState:SRGMediaPlayerPlaybackStateIdle withUserInfo:nil];
                    
                    self.startTimeValue = nil;
                    self.startCompletionHandler = nil;
                    
                    NSError *error = SRGMediaPlayerControllerError(playerItem.error);
                    [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerPlaybackDidFailNotification
                                                                        object:self
                                                                      userInfo:@{ SRGMediaPlayerErrorKey: error }];
                }
            }
        }
        else if ([keyPath isEqualToString:@"pictureInPictureActive"] || [keyPath isEqualToString:@"pictureInPicturePossible"]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:SRGMediaPlayerPictureInPictureStateDidChangeNotification object:self];
        }
    }
    else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


#pragma mark Description

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p; playbackState: %@; mediaType: %@; streamType: %@; live: %@; "
                "contentURL: %@; segments: %@; userInfo: %@; minimumDVRWindowLength: %@; liveTolerance: %@>",
            [self class],
            self,
            SRGMediaPlayerControllerNameForPlaybackState(self.playbackState),
            SRGMediaPlayerControllerNameForMediaType(self.mediaType),
            SRGMediaPlayerControllerNameForStreamType(self.streamType),
            self.live ? @"YES" : @"NO",
            self.contentURL,
            self.segments,
            self.userInfo,
            @(self.minimumDVRWindowLength),
            @(self.liveTolerance)];
}

@end

#pragma mark Functions

static NSError *SRGMediaPlayerControllerError(NSError *underlyingError)
{
    NSCParameterAssert(underlyingError);
    return [NSError errorWithDomain:SRGMediaPlayerErrorDomain code:SRGMediaPlayerErrorPlayback userInfo:@{ NSLocalizedDescriptionKey: SRGMediaPlayerLocalizedString(@"The media cannot be played", nil),
                                                                                                           NSUnderlyingErrorKey: underlyingError }];
}

static NSString *SRGMediaPlayerControllerNameForPlaybackState(SRGMediaPlayerPlaybackState playbackState)
{
    static NSDictionary<NSNumber *, NSString *> *s_names;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_names = @{ @(SRGMediaPlayerPlaybackStateIdle) : @"idle",
                     @(SRGMediaPlayerPlaybackStatePreparing) : @"preparing",
                     @(SRGMediaPlayerPlaybackStatePlaying) : @"playing",
                     @(SRGMediaPlayerPlaybackStateSeeking) : @"seeking",
                     @(SRGMediaPlayerPlaybackStatePaused) : @"paused",
                     @(SRGMediaPlayerPlaybackStateStalled) : @"stalled",
                     @(SRGMediaPlayerPlaybackStateEnded) : @"ended" };
    });
    return s_names[@(playbackState)] ?: @"unknown";
}

static NSString *SRGMediaPlayerControllerNameForMediaType(SRGMediaPlayerMediaType mediaType)
{
    static NSDictionary<NSNumber *, NSString *> *s_names;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_names = @{ @(SRGMediaPlayerMediaTypeVideo) : @"video",
                     @(SRGMediaPlayerMediaTypeAudio) : @"audio" };
    });
    return s_names[@(mediaType)] ?: @"unknown";
}

static NSString *SRGMediaPlayerControllerNameForStreamType(SRGMediaPlayerStreamType streamType)
{
    static NSDictionary<NSNumber *, NSString *> *s_names;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_names = @{ @(SRGMediaPlayerStreamTypeOnDemand) : @"on-demand",
                     @(SRGMediaPlayerStreamTypeLive) : @"live",
                     @(SRGMediaPlayerStreamTypeOnDemand) : @"DVR" };
    });
    return s_names[@(streamType)] ?: @"unknown";
}
