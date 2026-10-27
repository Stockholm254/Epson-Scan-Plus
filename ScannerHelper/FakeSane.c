// Test-only backend. It never touches USB; cancellation must drain to EOF.
#include <sane/sane.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <math.h>
static const char *names[] = {"", "source", "mode", "depth", "film-type", "color-correction",
  "gamma-correction", "red-gamma-table", "green-gamma-table", "blue-gamma-table", "sharpness",
  "mirror", "preview", "wait-for-button", "autofocus", "resolution", "tl-x", "tl-y", "br-x", "br-y"};
static SANE_Option_Descriptor opts[20];
static unsigned char values[20][1024];
static SANE_Range xr, yr;
static SANE_Word dpis[] = {9,150,300,600,1200,1800,2400,3200,4800,6400};
static SANE_Parameters parameters;
static size_t offset;
static int started, exhausted, stalled;
SANE_Status sane_init(SANE_Int *version, SANE_Auth_Callback cb) {
  (void)cb; *version = SANE_VERSION_CODE(1, 4, 0);
  xr = (SANE_Range){0, SANE_FIX(149.8599853515625), 0};
  yr = (SANE_Range){0, SANE_FIX(246.37998962402344), 0};
  for (int i = 1; i < 20; i++) {
    opts[i] = (SANE_Option_Descriptor){.name=names[i], .size=4, .type=SANE_TYPE_INT,
      .cap=SANE_CAP_SOFT_SELECT | SANE_CAP_SOFT_DETECT};
    if (i==1 || i==2 || (i>=4 && i<=6)) { opts[i].type=SANE_TYPE_STRING; opts[i].size=64; }
    if (i>=7 && i<=9) opts[i].size=1024;
    if (i>=16) {
      opts[i].type=SANE_TYPE_FIXED; opts[i].unit=SANE_UNIT_MM;
      opts[i].constraint_type=SANE_CONSTRAINT_RANGE;
      opts[i].constraint.range=(i%2==0) ? &xr : &yr;
    }
  }
  opts[15].constraint_type=SANE_CONSTRAINT_WORD_LIST;
  opts[15].constraint.word_list=dpis;
  started=exhausted=0; return SANE_STATUS_GOOD;
}
void sane_exit(void) {}
void sanei_usb_set_timeout(SANE_Int timeout) { (void)timeout; }
SANE_Status sane_get_devices(const SANE_Device ***devices, SANE_Bool local) {
  (void)local;
  static SANE_Device device={"libusb:FAKE", "Test", "No hardware", "fake"};
  static const SANE_Device *list[]={&device,NULL}; *devices=list; return SANE_STATUS_GOOD;
}
SANE_Status sane_open(SANE_String_Const name, SANE_Handle *handle) { (void)name; *handle=opts; return SANE_STATUS_GOOD; }
void sane_close(SANE_Handle handle) {
  (void)handle;
  if (started && !exhausted) { fputs("FAIL: close before drain\n",stderr); _exit(90); }
  if (started) fputs("FAKE: current transfer drained to EOF before closing\n",stderr);
}
void sane_cancel(SANE_Handle handle) { (void)handle; fputs("FAIL: hard CAN path called\n",stderr); _exit(91); }
const SANE_Option_Descriptor *sane_get_option_descriptor(SANE_Handle h, SANE_Int index) { (void)h; return &opts[index]; }
SANE_Status sane_control_option(SANE_Handle h, SANE_Int index, SANE_Action action, void *value, SANE_Int *info) {
  (void)h; if (info) *info=0;
  if (!index) { *(SANE_Int *)value=20; return SANE_STATUS_GOOD; }
  if (action==SANE_ACTION_SET_VALUE) memcpy(values[index],value,opts[index].size);
  else memcpy(value,values[index],opts[index].size);
  return SANE_STATUS_GOOD;
}
SANE_Status sane_get_parameters(SANE_Handle h, SANE_Parameters *p) {
  (void)h; double dpi=*(SANE_Word *)values[15];
  int width=(int)round(SANE_UNFIX(*(SANE_Word *)values[18]-*(SANE_Word *)values[16])/25.4*dpi);
  int height=(int)round(SANE_UNFIX(*(SANE_Word *)values[19]-*(SANE_Word *)values[17])/25.4*dpi);
  width &= ~7;
  parameters=(SANE_Parameters){SANE_FRAME_RGB,SANE_TRUE,width*6,width,height,16};
  *p=parameters; return SANE_STATUS_GOOD;
}
SANE_Status sane_start(SANE_Handle h) { (void)h; started=1; stalled=0; offset=0; return SANE_STATUS_GOOD; }
SANE_Status sane_read(SANE_Handle h, SANE_Byte *data, SANE_Int max, SANE_Int *length) {
  (void)h; size_t total=(size_t)parameters.bytes_per_line*parameters.lines;
  if (offset>=total) { *length=0; exhausted=1; return SANE_STATUS_EOF; }
  usleep(30000);
  // FAKE_SANE_STALL_SECONDS pauses once mid-transfer, like a scanner that stops sending data.
  const char *stall=getenv("FAKE_SANE_STALL_SECONDS");
  if (stall && !stalled && offset>=total/2) {
    stalled=1;
    for (unsigned left=(unsigned)atoi(stall); left; ) left=sleep(left);  // SIGALRM ends sleep() early
  }
  *length=(SANE_Int)((total-offset < (size_t)max) ? total-offset : (size_t)max);
  memset(data,0x45,*length); offset+=*length; return SANE_STATUS_GOOD;
}
SANE_String_Const sane_strstatus(SANE_Status status) { return status==SANE_STATUS_GOOD ? "good" : "test error"; }
