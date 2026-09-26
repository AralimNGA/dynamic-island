#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
int main(int argc,char**argv){@autoreleasepool{
  dlopen("/System/Library/PrivateFrameworks/Rapport.framework/Rapport",RTLD_NOW);
  id c=[objc_getClass("RPCompanionLinkClient") new];
  [c setValue:^(id dev){printf("FOUND model=%s hotspotInfo=0x%x statusFlags=0x%llx\n",[[[dev valueForKey:@"model"] description] UTF8String],[[dev valueForKey:@"hotspotInfo"] unsignedIntValue],[[dev valueForKey:@"statusFlags"] unsignedLongLongValue]);fflush(stdout);} forKey:@"deviceFoundHandler"];
  ((void(*)(id,SEL,id))objc_msgSend)(c,sel_registerName("activateWithCompletion:"),^(NSError*e){printf("activate: %s\n",e?[[e description] UTF8String]:"OK");fflush(stdout);});
  [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:10]];
  NSArray *a=[c valueForKey:@"activeDevices"]; printf("activeDevices=%lu\n",(unsigned long)a.count);
  ((void(*)(id,SEL))objc_msgSend)(c,sel_registerName("invalidate"));
}}
