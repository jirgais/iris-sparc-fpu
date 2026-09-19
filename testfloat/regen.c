#include <stdlib.h>
#include <math.h>
#include <fenv.h>
#include <time.h>
#include <inttypes.h>
#include <stdio.h>

int get_accex ()
{
  int fexc, accx;

  fexc = fetestexcept (FE_ALL_EXCEPT);
  accx = 0;
  if (fexc & FE_INEXACT)
    accx |= 1;
  if (fexc & FE_DIVBYZERO)
    accx |= 2;
  if (fexc & FE_UNDERFLOW)
    accx |= 4;
  if (fexc & FE_OVERFLOW)
    accx |= 8;
  if (fexc & FE_INVALID)
    accx |= 0x10;
  return accx;
}

int clear_accex ()
{
  feclearexcept (FE_ALL_EXCEPT);
}

int main(int argc, char* argv[])
{
  int opcode = 0;
  int op = 0;
  char *tmps, buf[128];
  union {
   float f;
   unsigned int i;
   int ii;
  } f1, f2, f5;
  union {
   double f;
   unsigned long int i;
  } d1, d2, d5;
  unsigned long int tmp;
  unsigned int excep, i, nc, fcc;
  unsigned int rm = 0;
  char *n;

  if (argc > 1) {
    opcode = atoi(argv[1]);
  }
  if (argc > 2) {
    rm = atoi(argv[2]);
  }
  switch (rm) {
  case 1:
    fesetround(FE_TOWARDZERO);
    break;
  case 2:
    fesetround(FE_UPWARD);
    break;
  case 3:
    fesetround(FE_DOWNWARD);
    break;
  }

  while (!feof(stdin)){

    clear_accex ();
    n = fgets(buf, 128, stdin);
    tmps = buf;
    if (!opcode)
      nc = sscanf(buf, "%03X ", &op);
    else
      op = opcode;
    tmps = &buf[4];
//    printf("%X %s", op, tmps);
    switch (op) {
    case 0x41:
      sscanf(tmps, "%08X %08X", &f1.i, &f2.i);
      f5.f = f1.f + f2.f;
      excep = get_accex ();
      printf("%03X %08X %08X %08X %02X\n", op, f1.i, f2.i, f5.i, excep);
      break;
    case 0x42:
      sscanf(tmps, "%016lX %016lX", &d1.i, &d2.i);
      d5.f = d1.f + d2.f;
      excep = get_accex ();
      printf("%03X %016lX %016lX %016lX %02X\n", op, d1.i, d2.i, d5.i, excep);
      break;
    case 0x49:  // fadds
      sscanf(tmps, "%08X %08X", &f1.i, &f2.i);
      f5.f = f1.f * f2.f;
      excep = get_accex ();
      printf("%03X %08X %08X %08X %02X\n", op, f1.i, f2.i, f5.i, excep);
      break;
    case 0x251:  // fcmps
    case 0x255:  // fcmpes
      sscanf(tmps, "%08X %08X", &f1.i, &f2.i);
      if (f1.f == f2.f)
        fcc = 3;
      else if (f1.f < f2.f)
        fcc = 2;
      else if (f1.f > f2.f)
        fcc = 1;
      else
        fcc = 0;
      excep = 0; //get_accex ();
      if ((fcc == 0) && (op == 0x255)) {
        excep |= 0x10;
      } else {
        if (fcc == 0) {
          if ((isnan(f1.f) && !((f1.i >> 22) & 1)) ||
            (isnan(f2.f) && !((f2.i >> 22) & 1)))
          excep = 0x10; //clear_accex (); // nv exception only on signaling NaN
        }
      }
      printf("%03X %08X %08X %X %02X\n", op, f1.i, f2.i, (~fcc) & 3, excep);
      break;
    case 0x252:  // fcmpd
    case 0x256:  // fcmped
      sscanf(tmps, "%016lX %016lX", &d1.i, &d2.i);
      if (d1.f == d2.f)
        fcc = 3;
      else if (d1.f < d2.f)
        fcc = 2;
      else if (d1.f > d2.f)
        fcc = 1;
      else
        fcc = 0;
      excep = 0; //get_accex ();
      if ((fcc == 0) && (op == 0x256)) {
        excep |= 0x10;
      } else {
        if (fcc == 0) {
          if ((isnan(d1.f) && !((d1.i >> 51) & 1)) ||
            (isnan(d2.f) && !((d2.i >> 51) & 1)))
          excep = 0x10; //clear_accex (); // nv exception only on signaling NaN
        }
      }
      printf("%03X %016lX %016lX %X %02X\n", op, d1.i, d2.i, (~fcc) & 3, excep);
      break;
    case 0xC6:   // fdtos
      sscanf(tmps, "%016lX", &d2.i);
      f5.f = d2.f;
      excep = get_accex ();
      printf("%03X %016lX %08X %02X\n", op, d2.i, f5.i, excep);
      break;
    case 0xD1:    // fstoi
      sscanf(tmps, "%08X", &f2.i);
      f5.ii = f2.f;
      if ((f5.i == 0x80000000) && !(f2.i >> 31)) // positive ovf returns max int
        f5.i = 0x7fffffff;
      excep = get_accex ();
      printf("%03X %08X %08X %02X\n", op, f2.i, f5.i, excep);
      break;
    case 0xD2:    // fdtoi
      sscanf(tmps, "%016lX", &d2.i);
      f5.ii = d2.f;
      if ((f5.i == 0x80000000) && !(d2.i >> 63)) // positive ovf returns max int
        f5.i = 0x7fffffff;
      excep = get_accex ();
      printf("%03X %016lX %08X %02X\n", op, d2.i, f5.i, excep);
      break;
    }
  }
}
