// Las declaraciones de la API privada se adaptaron de Chromium.
// Copyright 2022 The Chromium Authors. BSD-3-Clause; ver THIRD_PARTY_NOTICES.md.
#import "VirtualDisplay.h"

@interface NSObject (ISDPrivateDisplayAPI)
@property(nonatomic) unsigned int vendorID, productID, serialNum, serialNumber;
@property(nonatomic, strong) NSString *name;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int maxPixelsWide, maxPixelsHigh;
@property(nonatomic) CGPoint redPrimary, greenPrimary, bluePrimary, whitePoint;
@property(nonatomic, strong) id queue;
@property(nonatomic, readonly) unsigned int displayID;
@property(nonatomic) unsigned int hiDPI;
@property(nonatomic, strong) NSArray *modes;
- (id)initWithDescriptor:(id)descriptor;
- (id)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)rate;
- (BOOL)applySettings:(id)settings;
@end

@implementation ISDVirtualDisplay {
    id _display;
}
+ (BOOL)isAvailable {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor")
        && NSClassFromString(@"CGVirtualDisplayMode") && NSClassFromString(@"CGVirtualDisplaySettings");
}
- (CGDirectDisplayID)displayID { return _display ? [_display displayID] : kCGNullDirectDisplay; }
- (BOOL)startWithWidth:(uint32_t)width height:(uint32_t)height
          refreshRate:(double)refreshRate error:(NSError **)error {
    NSString *failure = nil;
    if (_display) failure = @"Ya existe una pantalla virtual en esta sesión.";
    else if (![ISDVirtualDisplay isAvailable]) failure = @"Esta versión de macOS no expone CGVirtualDisplay.";
    else if (width < 640 || width > 3840 || height < 480 || height > 2160 ||
             refreshRate < 15 || refreshRate > 60) failure = @"Resolución o frecuencia fuera del rango del prototipo.";
    if (failure) {
        if (error) *error = [NSError errorWithDomain:@"ISDVirtualDisplay" code:1
                                          userInfo:@{NSLocalizedDescriptionKey: failure}];
        return NO;
    }
    @try {
        id descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
        [descriptor setQueue:dispatch_get_main_queue()];
        [descriptor setName:@"iMac por red"];
        [descriptor setVendorID:0x4953];
        [descriptor setProductID:1];
        uint32_t serial = arc4random_uniform(UINT32_MAX - 1) + 1;
        [descriptor setSerialNum:serial];
        if ([descriptor respondsToSelector:@selector(setSerialNumber:)]) [descriptor setSerialNumber:serial];
        [descriptor setMaxPixelsWide:width];
        [descriptor setMaxPixelsHigh:height];
        [descriptor setSizeInMillimeters:CGSizeMake(597, 336)];
        [descriptor setRedPrimary:CGPointMake(0.64, 0.33)];
        [descriptor setGreenPrimary:CGPointMake(0.30, 0.60)];
        [descriptor setBluePrimary:CGPointMake(0.15, 0.06)];
        [descriptor setWhitePoint:CGPointMake(0.3127, 0.3290)];
        _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
        if (!_display) @throw [NSException exceptionWithName:@"VirtualDisplay"
                                                    reason:@"macOS rechazó la pantalla virtual." userInfo:nil];
        id mode = [[NSClassFromString(@"CGVirtualDisplayMode") alloc] initWithWidth:width
                                                                          height:height refreshRate:refreshRate];
        id settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
        [settings setHiDPI:0];
        [settings setModes:@[mode]];
        if (![_display applySettings:settings]) @throw [NSException exceptionWithName:@"VirtualDisplay"
            reason:@"macOS rechazó la resolución de la pantalla virtual." userInfo:nil];
        return YES;
    } @catch (NSException *exception) {
        _display = nil;
        if (error) *error = [NSError errorWithDomain:@"ISDVirtualDisplay" code:2
            userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"Falló la API privada."}];
        return NO;
    }
}
- (void)stop { _display = nil; }
@end
