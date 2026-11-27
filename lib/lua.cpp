// Lua from Aseprite's fork (lua/ submodule), compiled the way Aseprite does it.
// Wrapped in extern "C" so the API keeps C symbol names for mlua.
// The standard headers come first so their C++ overloads keep C++ linkage.
#include <assert.h>
#include <ctype.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern "C" {
#define MAKE_LIB
#include "onelua.c"
}

// Host hooks the fork requires (see lauxlib.h).
// Filenames are UTF-8, so Windows needs the wide-char CRT functions.
#ifdef _WIN32
#include <windows.h>

static wchar_t* to_wide(const char* utf8) {
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, nullptr, 0);
  if (len <= 0) return nullptr;
  wchar_t* wide = static_cast<wchar_t*>(malloc(sizeof(wchar_t) * len));
  if (wide) MultiByteToWideChar(CP_UTF8, 0, utf8, -1, wide, len);
  return wide;
}
#endif

extern "C" FILE* lua_user_fopen(const char* fname, const char* mode) {
#ifdef _WIN32
  wchar_t* wname = to_wide(fname);
  wchar_t* wmode = to_wide(mode);
  FILE* f = (wname && wmode) ? _wfopen(wname, wmode) : nullptr;
  free(wname);
  free(wmode);
  return f;
#else
  return fopen(fname, mode);
#endif
}

extern "C" FILE* lua_user_freopen(const char* fname, const char* mode, FILE* stream) {
#ifdef _WIN32
  wchar_t* wname = to_wide(fname);
  wchar_t* wmode = to_wide(mode);
  FILE* f = (wname && wmode) ? _wfreopen(wname, wmode, stream) : nullptr;
  free(wname);
  free(wmode);
  return f;
#else
  return freopen(fname, mode, stream);
#endif
}
