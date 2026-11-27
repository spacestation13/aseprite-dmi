use mlua::prelude::*;
use std::panic;

/// Runs a Lua-facing function so that no Lua error unwinds out of this module.
///
/// Raising is unsafe here, on Linux, Aseprite links its C++ runtime statically, so an
/// exception thrown by this module's Lua can't be caught by Aseprite's `pcall` and aborts.
pub fn safe_lua_function<'lua, A, R, F>(
    lua: &'lua Lua,
    func: F,
    args: LuaMultiValue,
) -> LuaResult<(Option<R>, Option<String>)>
where
    A: FromLuaMulti,
    R: IntoLuaMulti,
    F: Fn(&'lua Lua, A) -> LuaResult<R>,
{
    let call = || func(lua, A::from_lua_multi(args, lua)?);
    match panic::catch_unwind(panic::AssertUnwindSafe(call)) {
        Ok(Ok(r)) => Ok((Some(r), None)),
        Ok(Err(err)) => Ok((None, Some(err.to_string()))),
        Err(panic_err) => {
            let msg = if let Some(s) = panic_err.downcast_ref::<&str>() {
                format!("internal error: {}", s)
            } else if let Some(s) = panic_err.downcast_ref::<String>() {
                format!("internal error: {}", s)
            } else {
                "internal error: unknown panic".to_string()
            };
            Ok((None, Some(msg)))
        }
    }
}

macro_rules! safe {
    ($func:ident) => {
        |lua, args| $crate::macros::safe_lua_function(lua, $func, args)
    };
}

pub(crate) use safe;
