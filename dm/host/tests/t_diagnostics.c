// 固定容量、時間窗、非阻塞回調與並行快照的測試，不需要遊戲檔案。
// Test fixed capacities, time windows, nonblocking callbacks and concurrent snapshots; no game files needed.
#include "../../ios/Sources/dm_diagnostics.c"
#include <assert.h>
#include <signal.h>
#include <unistd.h>

static void reset(void){dm_diag_configure(0);dm_diag_configure(1);}
static void *produce(void *arg){uint64_t k=(uintptr_t)arg;for(uint64_t i=0;i<100000;i++){uint64_t id=(k<<40)|i;dm_diag_record(DM_DIAG_AUDIO,id,id^123,id+1,id+2,id+3);}return NULL;}
int main(void){
    alarm(30);reset();uint64_t t=dm_diag_now();
    for(unsigned i=0;i<5;i++){dm_diag_record(DM_DIAG_AUDIO,i,0,0,0,0);events[i].ns=t+(uint64_t[]){0,20,30,60,100}[i]*1000000000ull;}
    dm_diag_snapshot *s=dm_diag_take(t+90*1000000000ull,60);assert(s&&s->event_count==2&&s->events[0].id==2&&s->events[1].id==3);dm_diag_snapshot_free(s);
    reset();for(unsigned i=0;i<DM_DIAG_EVENTS+17;i++)dm_diag_record(DM_DIAG_GPU,i,0,0,0,0);
    s=dm_diag_take(0,3600);assert(s->event_count==DM_DIAG_EVENTS&&s->event_overwrites==17&&s->events[0].id==17);dm_diag_snapshot_free(s);
    reset();pthread_mutex_lock(&mu);dm_diag_record(DM_DIAG_AUDIO,1,0,0,0,0);dm_diag_log_write("x",1);pthread_mutex_unlock(&mu);
    assert(atomic_load(&event_drops)==1&&atomic_load(&log_drops)==1&&event_seq==0&&log_seq==0);
    char large[20000];memset(large,'a',sizeof large);dm_diag_log_write(large,sizeof large);assert(atomic_load(&log_drops)==1+sizeof large-16384);
    uint64_t cursor=0;char out[32768];assert(dm_diag_logs_after(&cursor,out,sizeof out)==16384);
    for(unsigned i=0;i<DM_DIAG_LOGS+10;i++)dm_diag_log_write("line\n",5);
    cursor=0;size_t n=dm_diag_logs_after(&cursor,out,sizeof out);assert(n==DM_DIAG_LOGS*5);assert(!memcmp(out,"line\n",5));
    reset();pthread_t threads[4];for(uintptr_t i=0;i<4;i++)assert(!pthread_create(&threads[i],NULL,produce,(void *)i));
    for(int i=0;i<15;i++){s=dm_diag_take(0,60);assert(s);for(size_t j=0;j<s->event_count;j++){dm_diag_event *e=&s->events[j];assert(e->a==(e->id^123)&&e->b==e->id+1&&e->c==e->id+2&&e->d==e->id+3);}dm_diag_snapshot_free(s);}
    for(int i=0;i<4;i++)pthread_join(threads[i],NULL);
    s=dm_diag_take(0,60);assert(s->event_count<=DM_DIAG_EVENTS);assert(s->event_count+s->event_overwrites+s->event_drops==400000);
    char *csv=NULL;size_t bytes=0;FILE *f=open_memstream(&csv,&bytes);dm_diag_write_events(f,s);assert(!fclose(f)&&bytes>40&&!memcmp(csv,"monotonic_ns,kind,id",19));free(csv);dm_diag_snapshot_free(s);
    dm_diag_configure(0);dm_diag_record(DM_DIAG_AUDIO,0,0,0,0,0);s=dm_diag_take(0,60);assert(s->event_count==0);dm_diag_snapshot_free(s);
    // 停止診斷錄製後，舊式應用程式日誌仍有自己的固定容量。
    // With diagnostic recording off, legacy application logs still have a fixed capacity.
    cursor=log_seq;dm_diag_log_write("legacy\n",7);assert(dm_diag_logs_after(&cursor,out,sizeof out)==7);
    printf("PASS diagnostics: %zu bytes of fixed ring storage; time, overflow, contention, concurrency and CSV checks\n",sizeof events+sizeof logs);return 0;
}
