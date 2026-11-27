//! Statically links Lua from Aseprite's fork, so the Lua operating
//! on Aseprite's `lua_State` from this module matches Aseprite's.

fn main() {
    println!("cargo::rerun-if-changed=lua");
    println!("cargo::rerun-if-changed=lua.cpp");

    assert!(
        std::path::Path::new("lua/onelua.c").is_file(),
        "lib/lua is missing; run `git submodule update --init`"
    );

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .file("lua.cpp")
        .include("lua")
        .define("LUA_FLOORN2I", "F2Ifloor") // aseprite float memes
        .define("HAVE_SYSTEM", None)
        .warnings(false);

    // luaconf.h picks LUA_USE_WINDOWS itself.
    match std::env::var("CARGO_CFG_TARGET_OS").as_deref() {
        Ok("macos") => build.define("LUA_USE_MACOSX", None),
        Ok("windows") => &mut build,
        _ => build.define("LUA_USE_LINUX", None),
    };
    // MSVC needs this for C++ exceptions, which Lua's error handling uses
    if build.get_compiler().is_like_msvc() {
        build.flag("/EHsc");
    }

    // Name must match LUA_LIB_NAME in .cargo/config.toml
    build.compile("lua_aseprite");
}
