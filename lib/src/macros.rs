use mlua::prelude::*;
use std::panic;

pub fn safe_lua_function<'lua, A, R, F>(
    lua: &'lua Lua,
    func: F,
    multi: A,
) -> LuaResult<(Option<R>, Option<String>)>
where
    A: FromLuaMulti,
    R: IntoLuaMulti,
    F: Fn(&'lua Lua, A) -> LuaResult<R>,
{
    match panic::catch_unwind(panic::AssertUnwindSafe(|| func(lua, multi))) {
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
