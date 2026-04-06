/*
 * lua_compat.c — Lua 5.4 symbol scanner for Linux
 *
 * Aseprite bundles Lua 5.4 compiled as C++, which gives every Lua API function
 * a C++ mangled name (e.g. lua_gettop → _Z10lua_gettopP9lua_State). The dynamic
 * linker cannot match those to the plain C names that mlua expects.
 *
 * At library load time this file:
 *   1. Walks the host binary's ELF .symtab via /proc/self/exe.
 *   2. For each needed symbol, tries the plain C name first, then looks for any
 *      symbol whose mangled name begins with _Z<len><name> — which uniquely
 *      identifies the function regardless of its parameter types.
 *   3. Stores the resolved addresses as function pointers.
 *   4. Exposes plain-C-named wrapper functions so mlua can link against them.
 *
 * No changes to aseprite are required: .symtab is always present in a
 * self-built (non-stripped) binary and is readable from /proc/self/exe.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <fcntl.h>
#include <link.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Opaque handle — we only ever use it as a pointer */
typedef struct lua_State lua_State;

/* Lua 5.4 on 64-bit Linux: these typedefs must match the ABI exactly */
typedef int           (*lua_CFunction)(lua_State *L);
typedef long           lua_KContext;   /* intptr_t = long on LP64          */
typedef int           (*lua_KFunction)(lua_State *L, int status, lua_KContext ctx);
typedef double         lua_Number;     /* LUA_REAL = double                 */
typedef long long      lua_Integer;   /* LUA_INT_TYPE = long long           */

/* --------------------------------------------------------------------------
 * Function pointer table
 * -------------------------------------------------------------------------- */
static int         (*p_lua_checkstack)(lua_State*, int);
static void        (*p_lua_close)(lua_State*);
static void        (*p_lua_copy)(lua_State*, int, int);
static void        (*p_lua_createtable)(lua_State*, int, int);
static int         (*p_lua_error)(lua_State*);
static int         (*p_lua_gc)(lua_State*, int, ...);
static void*       (*p_lua_getallocf)(lua_State*, void**);
static int         (*p_lua_getmetatable)(lua_State*, int);
static int         (*p_lua_gettable)(lua_State*, int);
static int         (*p_lua_gettop)(lua_State*);
static int         (*p_lua_isinteger)(lua_State*, int);
static lua_State*  (*p_lua_newthread)(lua_State*);
static void*       (*p_lua_newuserdatauv)(lua_State*, size_t, int);
static int         (*p_lua_pcallk)(lua_State*, int, int, int, lua_KContext, lua_KFunction);
static void        (*p_lua_pushboolean)(lua_State*, int);
static void        (*p_lua_pushcclosure)(lua_State*, lua_CFunction, int);
static void        (*p_lua_pushinteger)(lua_State*, lua_Integer);
static void        (*p_lua_pushlightuserdata)(lua_State*, void*);
static const char* (*p_lua_pushlstring)(lua_State*, const char*, size_t);
static void        (*p_lua_pushnil)(lua_State*);
static void        (*p_lua_pushnumber)(lua_State*, lua_Number);
static const char* (*p_lua_pushstring)(lua_State*, const char*);
static void        (*p_lua_pushvalue)(lua_State*, int);
static int         (*p_lua_rawget)(lua_State*, int);
static int         (*p_lua_rawgeti)(lua_State*, int, lua_Integer);
static int         (*p_lua_rawgetp)(lua_State*, int, const void*);
static void        (*p_lua_rawset)(lua_State*, int);
static void        (*p_lua_rawseti)(lua_State*, int, lua_Integer);
static void        (*p_lua_rawsetp)(lua_State*, int, const void*);
static void        (*p_lua_rotate)(lua_State*, int, int);
static int         (*p_lua_setmetatable)(lua_State*, int);
static void        (*p_lua_settable)(lua_State*, int);
static void        (*p_lua_settop)(lua_State*, int);
static int         (*p_lua_toboolean)(lua_State*, int);
static lua_Integer (*p_lua_tointegerx)(lua_State*, int, int*);
static const char* (*p_lua_tolstring)(lua_State*, int, size_t*);
static lua_Number  (*p_lua_tonumberx)(lua_State*, int, int*);
static const void* (*p_lua_topointer)(lua_State*, int);
static lua_State*  (*p_lua_tothread)(lua_State*, int);
static void*       (*p_lua_touserdata)(lua_State*, int);
static int         (*p_lua_type)(lua_State*, int);
static const char* (*p_lua_typename)(lua_State*, int);
static void        (*p_lua_xmove)(lua_State*, lua_State*, int);

static int         (*p_luaL_checkstack)(lua_State*, int, const char*);
static int         (*p_luaL_ref)(lua_State*, int);
static const char* (*p_luaL_tolstring)(lua_State*, int, size_t*);
static void        (*p_luaL_traceback)(lua_State*, lua_State*, const char*, int);

/* --------------------------------------------------------------------------
 * ELF scanner
 * -------------------------------------------------------------------------- */

static uintptr_t exe_base = 0;

static int phdr_callback(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    /* The first entry is always the main executable */
    *(uintptr_t *)data = (uintptr_t)info->dlpi_addr;
    return 1; /* stop after first */
}

/*
 * Look up `name` in the symbol table.
 *
 * Tries two forms:
 *   1. Exact match on the plain C name (works if Lua was compiled as C or
 *      the host added extern "C" guards).
 *   2. Prefix match on the Itanium C++ mangled form _Z<len><name>, which
 *      uniquely identifies the function regardless of parameter types.
 */
static uintptr_t find_sym(const char *strtab, const Elf64_Sym *syms, int nsyms,
                           const char *name) {
    size_t nlen = strlen(name);
    char prefix[256];
    snprintf(prefix, sizeof(prefix), "_Z%zu%s", nlen, name);
    size_t plen = strlen(prefix);

    for (int i = 0; i < nsyms; i++) {
        if (ELF64_ST_TYPE(syms[i].st_info) != STT_FUNC || syms[i].st_value == 0)
            continue;
        const char *sname = strtab + syms[i].st_name;
        if (strcmp(sname, name) == 0 || strncmp(sname, prefix, plen) == 0)
            return syms[i].st_value;
    }
    return 0;
}

#define RESOLVE(ptr, name) do {                                              \
    uintptr_t _off = find_sym(strtab, syms, nsyms, #name);                  \
    if (!_off) {                                                             \
        fprintf(stderr, "lua_compat: symbol not found: " #name "\n");       \
        abort();                                                             \
    }                                                                        \
    *(void **)(&(ptr)) = (void *)(exe_base + _off);                         \
} while (0)

__attribute__((constructor))
static void lua_compat_init(void) {
    dl_iterate_phdr(phdr_callback, &exe_base);

    int fd = open("/proc/self/exe", O_RDONLY);
    if (fd < 0) {
        perror("lua_compat: open /proc/self/exe");
        abort();
    }

    Elf64_Ehdr ehdr;
    if (pread(fd, &ehdr, sizeof(ehdr), 0) != (ssize_t)sizeof(ehdr) ||
        ehdr.e_shentsize != sizeof(Elf64_Shdr)) {
        fprintf(stderr, "lua_compat: unrecognised ELF format\n");
        abort();
    }

    Elf64_Shdr *shdrs = malloc(ehdr.e_shnum * sizeof(Elf64_Shdr));
    pread(fd, shdrs, ehdr.e_shnum * sizeof(Elf64_Shdr), ehdr.e_shoff);

    Elf64_Shdr *symtab_hdr = NULL, *strtab_hdr = NULL;
    for (int i = 0; i < ehdr.e_shnum; i++) {
        if (shdrs[i].sh_type == SHT_SYMTAB) {
            symtab_hdr = &shdrs[i];
            strtab_hdr = &shdrs[symtab_hdr->sh_link];
            break;
        }
    }

    if (!symtab_hdr) {
        fprintf(stderr, "lua_compat: no .symtab found — "
                "is the aseprite binary stripped?\n");
        abort();
    }

    int nsyms = (int)(symtab_hdr->sh_size / sizeof(Elf64_Sym));
    Elf64_Sym *syms = malloc(symtab_hdr->sh_size);
    pread(fd, syms, symtab_hdr->sh_size, symtab_hdr->sh_offset);

    char *strtab = malloc(strtab_hdr->sh_size);
    pread(fd, strtab, strtab_hdr->sh_size, strtab_hdr->sh_offset);

    RESOLVE(p_lua_checkstack,        lua_checkstack);
    RESOLVE(p_lua_close,             lua_close);
    RESOLVE(p_lua_copy,              lua_copy);
    RESOLVE(p_lua_createtable,       lua_createtable);
    RESOLVE(p_lua_error,             lua_error);
    RESOLVE(p_lua_gc,                lua_gc);
    RESOLVE(p_lua_getallocf,         lua_getallocf);
    RESOLVE(p_lua_getmetatable,      lua_getmetatable);
    RESOLVE(p_lua_gettable,          lua_gettable);
    RESOLVE(p_lua_gettop,            lua_gettop);
    RESOLVE(p_lua_isinteger,         lua_isinteger);
    RESOLVE(p_lua_newthread,         lua_newthread);
    RESOLVE(p_lua_newuserdatauv,     lua_newuserdatauv);
    RESOLVE(p_lua_pcallk,            lua_pcallk);
    RESOLVE(p_lua_pushboolean,       lua_pushboolean);
    RESOLVE(p_lua_pushcclosure,      lua_pushcclosure);
    RESOLVE(p_lua_pushinteger,       lua_pushinteger);
    RESOLVE(p_lua_pushlightuserdata, lua_pushlightuserdata);
    RESOLVE(p_lua_pushlstring,       lua_pushlstring);
    RESOLVE(p_lua_pushnil,           lua_pushnil);
    RESOLVE(p_lua_pushnumber,        lua_pushnumber);
    RESOLVE(p_lua_pushstring,        lua_pushstring);
    RESOLVE(p_lua_pushvalue,         lua_pushvalue);
    RESOLVE(p_lua_rawget,            lua_rawget);
    RESOLVE(p_lua_rawgeti,           lua_rawgeti);
    RESOLVE(p_lua_rawgetp,           lua_rawgetp);
    RESOLVE(p_lua_rawset,            lua_rawset);
    RESOLVE(p_lua_rawseti,           lua_rawseti);
    RESOLVE(p_lua_rawsetp,           lua_rawsetp);
    RESOLVE(p_lua_rotate,            lua_rotate);
    RESOLVE(p_lua_setmetatable,      lua_setmetatable);
    RESOLVE(p_lua_settable,          lua_settable);
    RESOLVE(p_lua_settop,            lua_settop);
    RESOLVE(p_lua_toboolean,         lua_toboolean);
    RESOLVE(p_lua_tointegerx,        lua_tointegerx);
    RESOLVE(p_lua_tolstring,         lua_tolstring);
    RESOLVE(p_lua_tonumberx,         lua_tonumberx);
    RESOLVE(p_lua_topointer,         lua_topointer);
    RESOLVE(p_lua_tothread,          lua_tothread);
    RESOLVE(p_lua_touserdata,        lua_touserdata);
    RESOLVE(p_lua_type,              lua_type);
    RESOLVE(p_lua_typename,          lua_typename);
    RESOLVE(p_lua_xmove,             lua_xmove);
    RESOLVE(p_luaL_checkstack,       luaL_checkstack);
    RESOLVE(p_luaL_ref,              luaL_ref);
    RESOLVE(p_luaL_tolstring,        luaL_tolstring);
    RESOLVE(p_luaL_traceback,        luaL_traceback);

    free(syms);
    free(strtab);
    free(shdrs);
    close(fd);
}

/* --------------------------------------------------------------------------
 * Plain-C-named wrapper functions
 * -------------------------------------------------------------------------- */

int         lua_checkstack(lua_State *L, int n)                   { return p_lua_checkstack(L, n); }
void        lua_close(lua_State *L)                               { p_lua_close(L); }
void        lua_copy(lua_State *L, int from, int to)              { p_lua_copy(L, from, to); }
void        lua_createtable(lua_State *L, int na, int nh)         { p_lua_createtable(L, na, nh); }
int         lua_error(lua_State *L)                               { return p_lua_error(L); }
int         lua_gc(lua_State *L, int what, int data)              { return p_lua_gc(L, what, data); }
void*       lua_getallocf(lua_State *L, void **ud)                { return p_lua_getallocf(L, ud); }
int         lua_getmetatable(lua_State *L, int idx)               { return p_lua_getmetatable(L, idx); }
int         lua_gettable(lua_State *L, int idx)                   { return p_lua_gettable(L, idx); }
int         lua_gettop(lua_State *L)                              { return p_lua_gettop(L); }
int         lua_isinteger(lua_State *L, int idx)                  { return p_lua_isinteger(L, idx); }
lua_State*  lua_newthread(lua_State *L)                           { return p_lua_newthread(L); }
void*       lua_newuserdatauv(lua_State *L, size_t sz, int nuv)   { return p_lua_newuserdatauv(L, sz, nuv); }
int         lua_pcallk(lua_State *L, int na, int nr, int ef,
                       lua_KContext ctx, lua_KFunction k)         { return p_lua_pcallk(L, na, nr, ef, ctx, k); }
void        lua_pushboolean(lua_State *L, int b)                  { p_lua_pushboolean(L, b); }
void        lua_pushcclosure(lua_State *L, lua_CFunction f, int n){ p_lua_pushcclosure(L, f, n); }
void        lua_pushinteger(lua_State *L, lua_Integer n)          { p_lua_pushinteger(L, n); }
void        lua_pushlightuserdata(lua_State *L, void *p)          { p_lua_pushlightuserdata(L, p); }
const char* lua_pushlstring(lua_State *L, const char *s, size_t l){ return p_lua_pushlstring(L, s, l); }
void        lua_pushnil(lua_State *L)                             { p_lua_pushnil(L); }
void        lua_pushnumber(lua_State *L, lua_Number n)            { p_lua_pushnumber(L, n); }
const char* lua_pushstring(lua_State *L, const char *s)           { return p_lua_pushstring(L, s); }
void        lua_pushvalue(lua_State *L, int idx)                  { p_lua_pushvalue(L, idx); }
int         lua_rawget(lua_State *L, int idx)                     { return p_lua_rawget(L, idx); }
int         lua_rawgeti(lua_State *L, int idx, lua_Integer n)     { return p_lua_rawgeti(L, idx, n); }
int         lua_rawgetp(lua_State *L, int idx, const void *p)     { return p_lua_rawgetp(L, idx, p); }
void        lua_rawset(lua_State *L, int idx)                     { p_lua_rawset(L, idx); }
void        lua_rawseti(lua_State *L, int idx, lua_Integer n)     { p_lua_rawseti(L, idx, n); }
void        lua_rawsetp(lua_State *L, int idx, const void *p)     { p_lua_rawsetp(L, idx, p); }
void        lua_rotate(lua_State *L, int idx, int n)              { p_lua_rotate(L, idx, n); }
int         lua_setmetatable(lua_State *L, int idx)               { return p_lua_setmetatable(L, idx); }
void        lua_settable(lua_State *L, int idx)                   { p_lua_settable(L, idx); }
void        lua_settop(lua_State *L, int top)                     { p_lua_settop(L, top); }
int         lua_toboolean(lua_State *L, int idx)                  { return p_lua_toboolean(L, idx); }
lua_Integer lua_tointegerx(lua_State *L, int idx, int *isnum)     { return p_lua_tointegerx(L, idx, isnum); }
const char* lua_tolstring(lua_State *L, int idx, size_t *len)     { return p_lua_tolstring(L, idx, len); }
lua_Number  lua_tonumberx(lua_State *L, int idx, int *isnum)      { return p_lua_tonumberx(L, idx, isnum); }
const void* lua_topointer(lua_State *L, int idx)                  { return p_lua_topointer(L, idx); }
lua_State*  lua_tothread(lua_State *L, int idx)                   { return p_lua_tothread(L, idx); }
void*       lua_touserdata(lua_State *L, int idx)                 { return p_lua_touserdata(L, idx); }
int         lua_type(lua_State *L, int idx)                       { return p_lua_type(L, idx); }
const char* lua_typename(lua_State *L, int tp)                    { return p_lua_typename(L, tp); }
void        lua_xmove(lua_State *from, lua_State *to, int n)      { p_lua_xmove(from, to, n); }

int         luaL_checkstack(lua_State *L, int sz, const char *msg){ return p_luaL_checkstack(L, sz, msg); }
int         luaL_ref(lua_State *L, int t)                         { return p_luaL_ref(L, t); }
const char* luaL_tolstring(lua_State *L, int idx, size_t *len)    { return p_luaL_tolstring(L, idx, len); }
void        luaL_traceback(lua_State *L, lua_State *L1,
                           const char *msg, int level)            { p_luaL_traceback(L, L1, msg, level); }
