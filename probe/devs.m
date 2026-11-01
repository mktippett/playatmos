#import <CoreAudio/CoreAudio.h>
#import <Foundation/Foundation.h>
int main(){ AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain}; UInt32 sz; AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&sz);
 AudioDeviceID*ids=malloc(sz); AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&sz,ids);
 for(UInt32 i=0;i<sz/4;i++){ CFStringRef n,u; UInt32 s=sizeof n; a.mSelector=kAudioObjectPropertyName; AudioObjectGetPropertyData(ids[i],&a,0,NULL,&s,&n); a.mSelector=kAudioDevicePropertyDeviceUID; AudioObjectGetPropertyData(ids[i],&a,0,NULL,&s,&u);
  a.mSelector=kAudioDevicePropertyPreferredChannelLayout; a.mScope=kAudioObjectPropertyScopeOutput; UInt32 ls=0; NSMutableString*lab=[NSMutableString string];
  if(!AudioObjectGetPropertyDataSize(ids[i],&a,0,NULL,&ls)){AudioChannelLayout*l=malloc(ls);AudioObjectGetPropertyData(ids[i],&a,0,NULL,&ls,l); [lab appendFormat:@"tag 0x%x:",l->mChannelLayoutTag]; for(UInt32 k=0;k<l->mNumberChannelDescriptions;k++)[lab appendFormat:@" %u",l->mChannelDescriptions[k].mChannelLabel];}
  a.mScope=kAudioObjectPropertyScopeGlobal;
  printf("%u | %s | %s | %s\n",ids[i],[(__bridge NSString*)n UTF8String],[(__bridge NSString*)u UTF8String],lab.UTF8String);}
}
