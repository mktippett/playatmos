#include <libavformat/avformat.h>
int main(int c,char**v){ AVFormatContext*f=NULL; avformat_open_input(&f,v[1],NULL,NULL); avformat_find_stream_info(f,NULL); av_seek_frame(f,-1,f->duration/2,AVSEEK_FLAG_BACKWARD);
 for(unsigned i=0;i<f->nb_streams;i++){AVStream*s=f->streams[i]; int n=avformat_index_get_entries_count(s); if(!n)continue; const AVIndexEntry*e0=avformat_index_get_entry(s,0),*e1=avformat_index_get_entry(s,n>1?1:0),*el=avformat_index_get_entry(s,n-1);
  printf("st %u %s n %d tb %d/%d first %lld %lld last %lld flags %d\n",i,avcodec_get_name(s->codecpar->codec_id),n,s->time_base.num,s->time_base.den,e0->timestamp,e1->timestamp,el->timestamp,e0->flags);}
 printf("dur %lld start %lld\n",f->duration,f->start_time);}
