#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
int main(){@autoreleasepool{
  dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing",RTLD_NOW);
  id d=[objc_getClass("SFRemoteHotspotDevice") new];
  for(unsigned i=0;i<16;i++){
    id b=((id(*)(id,SEL,unsigned))objc_msgSend)(d,sel_registerName("batteryLifeFromInfo:"),i);
    id s=((id(*)(id,SEL,unsigned))objc_msgSend)(d,sel_registerName("signalStrengthFromInfo:"),i<<2);
    unsigned char n=((unsigned char(*)(id,SEL,unsigned))objc_msgSend)(d,sel_registerName("networkTypeFromInfo:"),i<<4);
    printf("info=%2u -> battery=%s | info=0x%02x -> signal=%s | info=0x%03x -> net=%u\n",i,[[b description] UTF8String],i<<2,[[s description] UTF8String],i<<4,n);
  }
}}
