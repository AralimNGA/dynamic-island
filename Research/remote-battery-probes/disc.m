#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
int main(int argc,char**argv){@autoreleasepool{
  dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing",RTLD_NOW);
  id d=[objc_getClass("SFDeviceDiscovery") new];
  unsigned long long flags = argc>1? strtoull(argv[1],NULL,0) : 0xFFFFFFFFULL;
  [d setValue:@(flags) forKey:@"discoveryFlags"];
  [d setValue:@(0xFFFFFFFF) forKey:@"changeFlags"];
  [d setValue:@"batteryprobe" forKey:@"purpose"];
  __block int found=0;
  void (^report)(id,const char*) = ^(id dev,const char*what){
    NSArray *bi=[dev valueForKey:@"batteryInfo"]; unsigned hi=[[dev valueForKey:@"hotspotInfo"] unsignedIntValue];
    NSMutableString *b=[NSMutableString string];
    for(id x in bi) [b appendFormat:@"(lvl=%.2f st=%ld type=%ld) ",[[x valueForKey:@"batteryLevel"] doubleValue],(long)[[x valueForKey:@"batteryState"] integerValue],(long)[[x valueForKey:@"batteryType"] integerValue]];
    printf("%s model=%s class=%u type=%ld paired=%d hotspotInfo=0x%x battery=[%s]\n",what,[[[dev valueForKey:@"model"] description] UTF8String],[[dev valueForKey:@"deviceClassCode"] unsignedIntValue],(long)[[dev valueForKey:@"deviceType"] integerValue],[[dev valueForKey:@"paired"] intValue],hi,[b UTF8String]); fflush(stdout);
  };
  [d setValue:^(id dev){found++; report(dev,"FOUND");} forKey:@"deviceFoundHandler"];
  [d setValue:^(id dev, unsigned ch){ if([[dev valueForKey:@"batteryInfo"] count]) report(dev,"CHANGED");} forKey:@"deviceChangedHandler"];
  ((void(*)(id,SEL,id))objc_msgSend)(d,sel_registerName("activateWithCompletion:"),^(NSError*e){printf("activate: %s\n",e?[[e description] UTF8String]:"OK");fflush(stdout);});
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:(argc>2?atof(argv[2]):15)]];
  ((void(*)(id,SEL))objc_msgSend)(d,sel_registerName("invalidate"));
  printf("found=%d\n",found);
}}
