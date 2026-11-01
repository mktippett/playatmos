#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
int main(){ AudioComponentDescription d={0}; AudioComponent c=NULL;
 while((c=AudioComponentFindNext(c,&d))){ AudioComponentDescription o; AudioComponentGetDescription(c,&o); CFStringRef n=NULL; AudioComponentCopyName(c,&n);
  UInt32 t=CFSwapInt32HostToBig(o.componentType),s=CFSwapInt32HostToBig(o.componentSubType),m=CFSwapInt32HostToBig(o.componentManufacturer);
  NSString*ns=(__bridge NSString*)n; if(strncmp((char*)&t,"adec",4)==0||[ns.lowercaseString containsString:@"dolby"]||[ns.lowercaseString containsString:@"atmos"]||[ns.lowercaseString containsString:@"spatial"]) printf("%.4s %.4s %.4s %s\n",(char*)&t,(char*)&s,(char*)&m,ns.UTF8String);}
}
