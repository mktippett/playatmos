#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
static void p4(const char*l,UInt32 v){UInt32 b=CFSwapInt32HostToBig(v);printf("%s%.4s",l,(char*)&b);}
int main(int argc,char**argv){@autoreleasepool{
  AVURLAsset*asset=[AVURLAsset assetWithURL:[NSURL fileURLWithPath:@(argv[1])]];
  AVAssetTrack*t=[[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
  CMAudioFormatDescriptionRef fd=(__bridge CMAudioFormatDescriptionRef)t.formatDescriptions[0];
  size_t cs=0; const void*ck=CMAudioFormatDescriptionGetMagicCookie(fd,&cs); printf("cookie %zu bytes:",cs); for(size_t i=0;i<cs;i++)printf(" %02x",((uint8_t*)ck)[i]); printf("\n");
  AudioStreamBasicDescription in=*CMAudioFormatDescriptionGetStreamBasicDescription(fd);
  AudioComponentDescription d={'adec','ec-3','appl',0,0}; AudioComponent c=AudioComponentFindNext(NULL,&d); AudioCodec codec; OSStatus st=AudioComponentInstanceNew(c,&codec); printf("inst %d\n",st);
  if(cs) { st=AudioCodecSetProperty(codec,kAudioCodecPropertyMagicCookie,(UInt32)cs,ck); printf("set cookie %d\n",st);}
  st=AudioCodecSetProperty(codec,kAudioCodecPropertyCurrentInputFormat,sizeof in,&in); printf("set in %d\n",st);
  UInt32 sz; Boolean w;
  UInt32 props[]={kAudioCodecPropertySupportedOutputFormats,kAudioCodecPropertyOutputFormatsForInputFormat,kAudioCodecPropertyAvailableNumberChannels,kAudioCodecPropertyCurrentOutputChannelLayout,kAudioCodecPropertyAvailableOutputChannelLayoutTags, kAudioCodecPropertyCurrentOutputFormat};
  for(int i=0;i<6;i++){ st=AudioCodecGetPropertyInfo(codec,props[i],&sz,&w); p4("prop ",props[i]); printf(" info st %d sz %u\n",st,sz); if(st)continue;
    uint8_t*buf=calloc(1,sz+64); 
    if(props[i]==kAudioCodecPropertyOutputFormatsForInputFormat){ memcpy(buf,&in,sizeof in); }
    st=AudioCodecGetProperty(codec,props[i],&sz,buf); printf("  get st %d sz %u\n",st,sz);
    if(props[i]==kAudioCodecPropertySupportedOutputFormats||props[i]==kAudioCodecPropertyOutputFormatsForInputFormat||props[i]==kAudioCodecPropertyCurrentOutputFormat){ AudioStreamBasicDescription*a=(void*)buf; for(UInt32 j=0;j<sz/sizeof*a;j++){p4("   ",a[j].mFormatID);printf(" ch %u sr %.0f flags %x bits %u\n",a[j].mChannelsPerFrame,a[j].mSampleRate,a[j].mFormatFlags,a[j].mBitsPerChannel);} }
    else if(props[i]==kAudioCodecPropertyCurrentOutputChannelLayout){printf("   tag 0x%x\n",((AudioChannelLayout*)buf)->mChannelLayoutTag);}
    else if(props[i]==kAudioCodecPropertyAvailableOutputChannelLayoutTags){for(UInt32 j=0;j<sz/4;j++)printf("   tag 0x%x\n",((UInt32*)buf)[j]);}
    else {AudioValueRange*r=(void*)buf; for(UInt32 j=0;j<sz/sizeof*r;j++)printf("   %g-%g\n",r[j].mMinimum,r[j].mMaximum);} }
  // format list from cookie
  AudioFormatInfo fi={in,ck,(UInt32)cs}; st=AudioFormatGetPropertyInfo(kAudioFormatProperty_FormatList,sizeof fi,&fi,&sz); printf("formatlist st %d sz %u\n",st,sz);
}}
