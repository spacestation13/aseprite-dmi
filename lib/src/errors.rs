use mlua::ExternalError as _;

pub enum ExternalError {
    Arboard(arboard::Error),
    Serde(serde_json::Error),
}

impl mlua::ExternalError for ExternalError {
    fn to_lua_err(self) -> mlua::Error {
        match self {
            Self::Arboard(err) => err.to_lua_err(),
            Self::Serde(err) => err.to_lua_err(),
        }
    }
}

impl From<ExternalError> for mlua::Error {
    fn from(error: ExternalError) -> Self {
        error.to_lua_err()
    }
}

impl From<crate::dmi::DmiError> for mlua::Error {
    fn from(error: crate::dmi::DmiError) -> Self {
        error.to_lua_err()
    }
}
