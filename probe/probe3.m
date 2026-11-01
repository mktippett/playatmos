#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
int main(){ UInt32 sz=0; AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs,0,NULL,&sz); UInt32*ids=malloc(sz); AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs,0,NULL,&sz,ids);
 for(UInt32 i=0;i<sz/4;i++){UInt32 b=CFSwapInt32HostToBig(ids[i]); printf("%.4s ",(char*)&b);} printf("\n");
 UInt32 f='ec+3'; AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders,4,&f,&sz); printf("ec+3 decoders bytes %u\n",sz);
 AudioClassDescription*cd=malloc(sz+1); OSStatus st=AudioFormatGetProperty(kAudioFormatProperty_Decoders,4,&f,&sz,cd); printf("st %d\n",st);
 for(UInt32 i=0;i<sz/sizeof(*cd);i++){UInt32 a=CFSwapInt32HostToBig(cd[i].mSubType),b=CFSwapInt32HostToBig(cd[i].mManufacturer);printf("dec %.4s %.4s\n",(char*)&a,(char*)&b);}
}
