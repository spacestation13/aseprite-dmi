use std::fs;
use std::path::Path;

use dmi::{RawSession, read_dmi_metadata};

fn session(metadata: &str) -> RawSession {
    RawSession {
        original_width: 96,
        original_height: 64,
        cell_width: 32,
        cell_height: 32,
        metadata: metadata.to_string(),
    }
}

#[test]
fn session_round_trips_after_other_sprite_data() {
    let session = session("# BEGIN DMI\nstate = \"caf\u{E9} \u{2014} \u{1F389}\"\n# END DMI\n");
    let data = format!("user data\n{}", session.encode());

    assert!(RawSession::is_marked(data.as_bytes()));
    assert_eq!(RawSession::decode(data.as_bytes()), Some(session));
}

#[test]
fn session_format_is_unchanged() {
    // What earlier versions stored in sprite.data; sprites saved with it must still load.
    let stored = "\n__aseprite_dmi_raw__\nv1\n96\n64\n32\n32\n5\nhello";
    assert_eq!(session("hello").encode(), stored);
    assert_eq!(
        RawSession::decode(format!("{stored} trailing").as_bytes()),
        Some(session("hello"))
    );
}

#[test]
fn damaged_sessions_are_marked_but_unreadable() {
    let encoded = session("hello").encode();
    for damaged in [
        encoded.replace("\n96\n", "\n-96\n"),
        encoded.replace("\n5\n", "\n6\n"),
        encoded.replace("\n64\n", "\n\n"),
        encoded.replace("v1", "v2"),
        encoded[..encoded.len() - 10].to_string(),
    ] {
        assert!(RawSession::is_marked(damaged.as_bytes()), "{damaged:?}");
        assert_eq!(RawSession::decode(damaged.as_bytes()), None, "{damaged:?}");
    }
    assert!(!RawSession::is_marked(b"plain sprite data"));
    assert_eq!(RawSession::decode(b""), None);
}

#[test]
fn open_copies_the_dmi_and_reads_its_session() {
    let source = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/assets/anomaly.dmi");
    let temp =
        Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("raw-open-{}", std::process::id()));
    let _ = fs::remove_dir_all(&temp);

    let (session, png) = RawSession::open(&source, &temp).unwrap();
    assert_eq!(png, temp.join("raw_open.png"));
    assert_eq!(fs::read(&png).unwrap(), fs::read(&source).unwrap());
    assert_eq!(session.metadata, read_dmi_metadata(&source).unwrap());
    assert_eq!((session.cell_width, session.cell_height), (32, 32));
    let (width, height) = image::image_dimensions(&png).unwrap();
    assert_eq!(
        (session.original_width, session.original_height),
        (width, height)
    );

    fs::remove_dir_all(temp).unwrap();
}
