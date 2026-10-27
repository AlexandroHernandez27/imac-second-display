#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN
// Único punto de acceso a la API privada; el resto de la aplicación usa APIs públicas.
@interface ISDVirtualDisplay : NSObject
@property(nonatomic, readonly) CGDirectDisplayID displayID;
+ (BOOL)isAvailable;
- (BOOL)startWithWidth:(uint32_t)width height:(uint32_t)height
          refreshRate:(double)refreshRate error:(NSError **)error
    NS_SWIFT_NAME(start(width:height:refreshRate:));
- (void)stop;
@end
NS_ASSUME_NONNULL_END
