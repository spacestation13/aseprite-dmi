fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default() == "linux" {
        cc::Build::new()
            .file("lua_compat.c")
            .compile("lua_compat");
    }
}
