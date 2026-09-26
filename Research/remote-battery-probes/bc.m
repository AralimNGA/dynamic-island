#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
@interface Obs : NSObject @end
@implementation Obs
- (void)connectedDevicesDidChange:(NSArray*)devs { printf("observer: %lu devices\n",(unsigned long)devs.count); for(id d in devs) printf("  %s %ld%% internal=%d transport=%ld\n",[[[d valueForKey:@"name"] description] UTF8String],(long)[[d valueForKey:@"percentCharge"] integerValue],[[d valueForKey:@"internal"] intValue],(long)[[d valueForKey:@"transportType"] integerValue]); fflush(stdout);}
@end
int main(){@autoreleasepool{
  dlopen("/System/Library/PrivateFrameworks/BatteryCenter.framework/BatteryCenter",RTLD_NOW);
  id c=[objc_getClass("BCBatteryDeviceController") new];
  printf("before: %lu\n",(unsigned long)[[c valueForKey:@"connectedDevices"] count]);
  Obs *o=[Obs new];
  ((void(*)(id,SEL,id,id))objc_msgSend)(c,sel_registerName("addBatteryDeviceObserver:queue:"),o,dispatch_get_main_queue());
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
  NSArray *a=[c valueForKey:@"connectedDevices"]; printf("after: %lu\n",(unsigned long)a.count);
  for(id d in a) printf("  %s %ld%% internal=%d\n",[[[d valueForKey:@"name"] description] UTF8String],(long)[[d valueForKey:@"percentCharge"] integerValue],[[d valueForKey:@"internal"] intValue]);
}}
