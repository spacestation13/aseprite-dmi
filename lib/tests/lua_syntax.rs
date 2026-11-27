//! Compiles (without running) every .lua file under scripts/ and tools/tests/
//! with the Lua statically built from Aseprite's fork, so syntax errors are
//! caught without launching Aseprite. Run: `cargo test --test lua_syntax`.

use std::fs;
use std::path::{Path, PathBuf};

use mlua::Lua;

// Links the dmi crate, which carries the statically built Lua that mlua needs on Linux.
use dmi as _;

fn lua_files(dir: &Path, out: &mut Vec<PathBuf>) {
    let entries = fs::read_dir(dir).unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()));
    for entry in entries {
        let path = entry.unwrap().path();
        if path.is_dir() {
            lua_files(&path, out);
        } else if path.extension().is_some_and(|ext| ext == "lua") {
            out.push(path);
        }
    }
}

#[test]
fn lua_files_compile() {
    let repo = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let mut files = Vec::new();
    lua_files(&repo.join("scripts"), &mut files);
    lua_files(&repo.join("tools").join("tests"), &mut files);
    assert!(files.len() > 10, "found only {} .lua files", files.len());

    let lua = Lua::new();
    let errors: Vec<String> = files
        .iter()
        .filter_map(|path| {
            let source = fs::read(path).unwrap();
            let name = path
                .strip_prefix(repo)
                .unwrap_or(path)
                .display()
                .to_string();
            lua.load(source)
                .set_name(format!("@{name}"))
                .into_function()
                .err()
                .map(|e| e.to_string())
        })
        .collect();

    assert!(
        errors.is_empty(),
        "Lua syntax errors:\n{}",
        errors.join("\n")
    );
}
