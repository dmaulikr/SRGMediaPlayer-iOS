//
//  Copyright (c) SRG. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGAirplayButton.h"

#import "MPVolumeView+SRGMediaPlayer.h"
#import "NSBundle+SRGMediaPlayer.h"

#import <libextobjc/libextobjc.h>

static UIImage *SRGAirplayButtonImage(void);

static void commonInit(SRGAirplayButton *self);

@interface SRGAirplayButton ()

@property (nonatomic, weak) MPVolumeView *volumeView;
@property (nonatomic, weak) UIButton *fakeInterfaceBuilderButton;

@end

@implementation SRGAirplayButton

#pragma mark Object lifecycle

- (id)initWithFrame:(CGRect)frame
{
    if (self = [super initWithFrame:frame]) {
        commonInit(self);
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
    if (self = [super initWithCoder:aDecoder]) {
        commonInit(self);
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Overrides

- (void)willMoveToWindow:(UIWindow *)newWindow
{
    [super willMoveToWindow:newWindow];
    
    if (newWindow) {
        [self updateAppearance];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(srg_airplayButton_wirelessRoutesAvailableDidChange:)
                                                     name:MPVolumeViewWirelessRoutesAvailableDidChangeNotification
                                                   object:self.volumeView];
    }
    else {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:MPVolumeViewWirelessRoutesAvailableDidChangeNotification
                                                      object:self.volumeView];
    }
}

#pragma mark Notifications

- (void)srg_airplayButton_wirelessRoutesAvailableDidChange:(NSNotification *)notification
{
    [self updateAppearance];
}

#pragma mark Appearance

- (void)updateAppearance
{
    self.hidden = ! self.fakeInterfaceBuilderButton && ! self.volumeView.areWirelessRoutesAvailable;
}

#pragma mark Interface Builder integration

- (void)prepareForInterfaceBuilder
{
    // Use a fake button for Interface Builder rendering, since the volume view (and thus its Airplay button) is only
    // visible on a device
    UIButton *fakeInterfaceBuilderButton = [UIButton buttonWithType:UIButtonTypeSystem];
    fakeInterfaceBuilderButton.frame = self.bounds;
    fakeInterfaceBuilderButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [fakeInterfaceBuilderButton setImage:SRGAirplayButtonImage() forState:UIControlStateNormal];
    [self addSubview:fakeInterfaceBuilderButton];
    self.fakeInterfaceBuilderButton = fakeInterfaceBuilderButton;
}

@end

#pragma mark Functions

static UIImage *SRGAirplayButtonImage(void)
{
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *imagePath = [[NSBundle srg_mediaPlayerBundle] pathForResource:@"airplay" ofType:@"png"];
        image = [[UIImage imageWithContentsOfFile:imagePath] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    });
    return image;
}

static void commonInit(SRGAirplayButton *self)
{
    MPVolumeView *volumeView = [[MPVolumeView alloc] initWithFrame:self.bounds];
    volumeView.showsVolumeSlider = NO;
    volumeView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:volumeView];
    self.volumeView = volumeView;
    
    // Replace with custom image to be able to apply a tint color. The button color is automagically inherited from
    // the enclosing view (this works both at runtime and when rendering in Interface Builder)
    UIButton *airplayButton = volumeView.srg_airplayButton;
    [airplayButton setImage:SRGAirplayButtonImage() forState:UIControlStateNormal];
}
