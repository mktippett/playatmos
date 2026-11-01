#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
typedef struct { NSMutableArray *pkts; NSUInteger idx; AudioStreamPacketDescription pd; } Ctx;
static OSStatus inProc(AudioConverterRef c, UInt32 *np, AudioBufferList *bl, AudioStreamPacketDescription **pd, void *u){
  Ctx*x=u; if(x->idx>=x->pkts.count){*np=0;return noErr;}
  NSData*d=x->pkts[x->idx++]; bl->mNumberBuffers=1; bl->mBuffers[0].mData=(void*)d.bytes; bl->mBuffers[0].mDataByteSize=(UInt32)d.length; bl->mBuffers[0].mNumberChannels=0;
  x->pd=(AudioStreamPacketDescription){0,0,(UInt32)d.length}; if(pd)*pd=&x->pd; *np=1; return noErr;}
int main(int argc,char**argv){@autoreleasepool{
  int nch=argc>2?atoi(argv[2]):12; double t0=argc>3?atof(argv[3]):30;
  AVURLAsset*asset=[AVURLAsset assetWithURL:[NSURL fileURLWithPath:@(argv[1])]];
  AVAssetTrack*t=[[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
  AVAssetReader*r=[AVAssetReader assetReaderWithAsset:asset error:nil];
  AVAssetReaderTrackOutput*o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:t outputSettings:nil]; [r addOutput:o];
  r.timeRange=CMTimeRangeMake(CMTimeMakeWithSeconds(t0,48000),CMTimeMakeWithSeconds(60,48000)); [r startReading];
  Ctx x={[NSMutableArray array],0}; CMSampleBufferRef sb;
  while((sb=[o copyNextSampleBuffer])){ CMBlockBufferRef bb=CMSampleBufferGetDataBuffer(sb); const AudioStreamPacketDescription*pds=NULL; size_t npd=0;
    if(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(sb,&pds,&npd)) npd=0; npd/=sizeof(AudioStreamPacketDescription); size_t len=CMBlockBufferGetDataLength(bb); NSMutableData*md=[NSMutableData dataWithLength:len]; char*p=md.mutableBytes; CMBlockBufferCopyDataBytes(bb,0,len,p);
    static int dbg=0; if(dbg++<3) fprintf(stderr,"len %zu npd %zu ns %ld s0 %zu\n",len,npd,(long)CMSampleBufferGetNumSamples(sb),CMSampleBufferGetSampleSize(sb,0));
    if(npd) for(size_t i=0;i<npd;i++) [x.pkts addObject:[NSData dataWithBytes:p+pds[i].mStartOffset length:pds[i].mDataByteSize]];
    else { CMItemCount ns=CMSampleBufferGetNumSamples(sb); size_t off=0; for(CMItemCount i=0;i<ns;i++){size_t ss=CMSampleBufferGetSampleSize(sb,i); [x.pkts addObject:[NSData dataWithBytes:p+off length:ss]]; off+=ss;} } CFRelease(sb);}
  printf("packets %lu first len %lu\n",(unsigned long)x.pkts.count,(unsigned long)[x.pkts[0] length]);
  AudioStreamBasicDescription in={0}; in.mFormatID=argc>4?'ec-3':'ec+3'; in.mSampleRate=48000; in.mFramesPerPacket=1536; in.mChannelsPerFrame=nch;
  AudioStreamBasicDescription out={48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,4*nch,1,4*nch,nch,32,0};
  AudioConverterRef conv; OSStatus st=AudioConverterNew(&in,&out,&conv); printf("AudioConverterNew %d\n",(int)st); if(st) return 1;
  AudioChannelLayout lay={0}; lay.mChannelLayoutTag= nch==12?kAudioChannelLayoutTag_Atmos_7_1_4: nch==16?kAudioChannelLayoutTag_Atmos_9_1_6:kAudioChannelLayoutTag_Atmos_5_1_4;
  st=AudioConverterSetProperty(conv,kAudioConverterOutputChannelLayout,sizeof lay,&lay); printf("set out layout %d\n",(int)st);
  UInt32 sz=0; Boolean w; if(!AudioConverterGetPropertyInfo(conv,kAudioConverterOutputChannelLayout,&sz,&w)){AudioChannelLayout*l=malloc(sz);AudioConverterGetProperty(conv,kAudioConverterOutputChannelLayout,&sz,l);printf("out layout tag 0x%x\n",l->mChannelLayoutTag);}
  float*buf=malloc(4096*4*nch); double sum[32]={0}; long frames=0;
  for(;;){ UInt32 n=4096; AudioBufferList bl={1,{{nch,4096*4*nch,buf}}}; st=AudioConverterFillComplexBuffer(conv,inProc,&x,&n,&bl,NULL);
    if(st&&!n){printf("fill st %d\n",(int)st);break;} if(!n)break;
    for(UInt32 i=0;i<n;i++)for(int c=0;c<nch;c++){double v=buf[i*nch+c];sum[c]+=v*v;} frames+=n; }
  printf("frames %ld\nRMS dB:",frames); for(int c=0;c<nch;c++)printf(" %.1f",10*log10(sum[c]/(frames?frames:1)+1e-20)); printf("\n");
}}
