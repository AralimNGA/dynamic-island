#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
@interface Del : NSObject @end
@implementation Del
- (void)session:(id)sess updatedFoundDevices:(id)list {
  printf("[%.1f] %lu device(s)\n", CFAbsoluteTimeGetCurrent(), (unsigned long)[list count]);
  for (id d in list) {
    NSData* ad = [d valueForKey:@"advertisementData"];
    NSMutableString* hex=[NSMutableString string]; const unsigned char* b=ad.bytes; for (NSUInteger i=0;i<ad.length;i++) [hex appendFormat:@"%02x ", b[i]];
    printf("  %s | %s | batt=%s sig=%s net=%d cached=%d lastSeen=%.1f dup=%d companion=%d\n     adv(%lu)=%s\n",
      [[d valueForKey:@"deviceName"] UTF8String], [[[d valueForKey:@"model"] description] UTF8String],
      [[[d valueForKey:@"batteryLife"] description] UTF8String], [[[d valueForKey:@"signalStrength"] description] UTF8String],
      [[d valueForKey:@"networkType"] intValue], [[d valueForKey:@"cachedDevice"] intValue], [[d valueForKey:@"lastSeen"] doubleValue],
      [[d valueForKey:@"hasDuplicates"] intValue], [[d valueForKey:@"supportsCompanionLink"] intValue],
      (unsigned long)ad.length, hex.UTF8String);
  }
}
@end
int main(){ @autoreleasepool {
  dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_LAZY);
  id s = [[objc_getClass("SFRemoteHotspotSession") alloc] init];
  Del* d = [Del new]; [s setValue:d forKey:@"delegate"];
  [s performSelector:@selector(startBrowsing)];
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:12]];
  [s performSelector:@selector(stopBrowsing)];
}}
