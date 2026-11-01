// Capture input of a CoreAudio device via AUHAL; accumulate per-channel energy.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#include <math.h>
static AudioUnit gIn; static double gSum[32]; static double gWin[32]; static long gWinN; static int gSeries = -1; static long gFrames; static int gCh; static float gBuf[16384*32];
static AudioDeviceID devForUID(NSString*uid){ AudioObjectPropertyAddress a={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
  CFStringRef u=(__bridge CFStringRef)uid; AudioDeviceID d=0; UInt32 s=sizeof d; AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof u,&u,&s,&d); return d;}
static OSStatus capCB(void*r,AudioUnitRenderActionFlags*f,const AudioTimeStamp*ts,UInt32 bus,UInt32 n,AudioBufferList*io){
  AudioBufferList bl={1,{{gCh,n*4*gCh,gBuf}}}; OSStatus st=AudioUnitRender(gIn,f,ts,1,n,&bl); if(st) return st;
  for(UInt32 i=0;i<n;i++){for(int c=0;c<gCh;c++){double v=gBuf[i*gCh+c];gSum[c]+=v*v;gWin[c]+=v*v;}
    if(gSeries>=0 && ++gWinN==48000){ static const char*nm[12]={"L","R","C","LFE","Ls","Rs","Lrs","Rrs","Vhl","Vhr","Ltr","Rtr"}; int b=0; char line[400]; int o=0;
      for(int c=0;c<gCh;c++){ if(gWin[c]>gWin[b])b=c; o+=snprintf(line+o,sizeof line-o," %6.1f",10*log10(gWin[c]/48000+1e-20)); }
      fprintf(stderr,"t+%3ds  loudest %-3s |%s\n",gSeries++,gWin[b]>1e-12?nm[b]:"-",line); memset(gWin,0,sizeof gWin); gWinN=0; } }
  gFrames+=n; return noErr;}
static void capStart(NSString*uid,int ch){ gCh=ch; AudioComponentDescription d={kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
  AudioComponentInstanceNew(AudioComponentFindNext(NULL,&d),&gIn); UInt32 one=1,zero=0;
  AudioUnitSetProperty(gIn,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&one,4); AudioUnitSetProperty(gIn,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&zero,4);
  AudioDeviceID dev=devForUID(uid); OSStatus st=AudioUnitSetProperty(gIn,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&dev,4);
  AudioStreamBasicDescription f={48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,4*ch,1,4*ch,ch,32,0};
  st|=AudioUnitSetProperty(gIn,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,&f,sizeof f);
  AURenderCallbackStruct cb={capCB,NULL}; st|=AudioUnitSetProperty(gIn,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,0,&cb,sizeof cb);
  st|=AudioUnitInitialize(gIn); st|=AudioOutputUnitStart(gIn); fprintf(stderr,"capture dev %u st %d\n",dev,(int)st);}
static void capReport(void){ AudioOutputUnitStop(gIn); printf("captured frames %ld\nRMS dB [L R C LFE Ls Rs Lrs Rrs Vhl Vhr Ltr Rtr]:\n",gFrames);
  for(int c=0;c<gCh;c++)printf(" %.1f",10*log10(gSum[c]/(gFrames?gFrames:1)+1e-20)); printf("\n");}
