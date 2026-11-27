use std::fs;
use std::path::{Path, PathBuf};

use dmi::{CombineLayout, CombinePlan, DmiError, SerializedState, combine_plan, write_frame_bytes};

/// A fresh, empty temp directory for one test.
fn temp_dir(name: &str) -> PathBuf {
    let dir =
        Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("ops-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

fn state(name: &str, dirs: u32, frame_count: u32) -> SerializedState {
    SerializedState {
        name: name.to_string(),
        dirs,
        frame_key: format!("{name}.1"),
        frame_count,
        delays: (1..=frame_count).map(|frame| frame as f32).collect(),
        loop_: 2,
        rewind: true,
        movement: true,
        hotspots: vec!["1,2,1".to_string()],
    }
}

fn frame_file(temp: &Path, frame_key: &str, index: u32) -> PathBuf {
    temp.join(format!("{frame_key}.{index}.bytes"))
}

/// Writes 1x1 frame images whose pixel tells the state (`id`) and frame image index apart.
fn write_frames(temp: &Path, state: &SerializedState, id: u8) {
    for index in 0..state.dirs * state.frame_count {
        let pixel = [id, index as u8, 0, 255];
        write_frame_bytes(frame_file(temp, &state.frame_key, index), 1, 1, &pixel).unwrap();
    }
}

/// The (state id, frame image index) pixel of every frame image of `state`.
fn read_frames(temp: &Path, state: &SerializedState) -> Vec<(u8, u8)> {
    (0..state.dirs * state.frame_count)
        .map(|index| {
            let bytes = fs::read(frame_file(temp, &state.frame_key, index)).unwrap();
            assert_eq!(&bytes[..4], b"1\n1\n");
            (bytes[4], bytes[5])
        })
        .collect()
}

fn frame_files(temp: &Path) -> usize {
    fs::read_dir(temp).unwrap().count()
}

fn sources(plan: &CombinePlan) -> Vec<(usize, u32)> {
    plan.sources.clone()
}

#[test]
fn frame_bytes_reject_a_wrong_pixel_count() {
    let temp = temp_dir("format");
    let path = temp.join("frame.bytes");
    assert!(matches!(
        write_frame_bytes(&path, 2, 2, &[0; 8]),
        Err(DmiError::MissingData)
    ));
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn one_direction_takes_south_of_every_frame() {
    let states = [state("a", 4, 2), state("b", 1, 3)];
    let plan = combine_plan(&states, CombineLayout::FramesFirst, 1, false).unwrap();
    assert_eq!(plan.dirs, 1);
    assert_eq!(plan.frame_count, 5);
    assert_eq!(sources(&plan), [(0, 0), (0, 4), (1, 0), (1, 1), (1, 2)]);
    assert_eq!(plan.delays, [1., 2., 1., 2., 3.]);

    let plan = combine_plan(&states, CombineLayout::FramesFirst, 1, true).unwrap();
    assert_eq!(sources(&plan), [(0, 0), (1, 0)]);
    assert_eq!(plan.delays, [1., 1.]);
}

#[test]
fn frames_first_four_directions() {
    let states = [state("a", 4, 2), state("b", 1, 1)];
    let plan = combine_plan(&states, CombineLayout::FramesFirst, 4, false).unwrap();
    assert_eq!((plan.dirs, plan.frame_count), (4, 3));
    #[rustfmt::skip]
    assert_eq!(sources(&plan), [
        (0, 0), (0, 1), (0, 2), (0, 3),
        (0, 4), (0, 5), (0, 6), (0, 7),
        // A missing direction repeats south.
        (1, 0), (1, 0), (1, 0), (1, 0),
    ]);
    assert_eq!(plan.delays, [1., 2., 1.]);
}

#[test]
fn frames_first_eight_directions() {
    let states = [state("a", 4, 2), state("b", 8, 1)];
    let plan = combine_plan(&states, CombineLayout::FramesFirst, 8, true).unwrap();
    assert_eq!((plan.dirs, plan.frame_count), (8, 2));
    #[rustfmt::skip]
    assert_eq!(sources(&plan), [
        (0, 0), (0, 1), (0, 2), (0, 3), (0, 0), (0, 0), (0, 0), (0, 0),
        (1, 0), (1, 1), (1, 2), (1, 3), (1, 4), (1, 5), (1, 6), (1, 7),
    ]);
    assert_eq!(plan.delays, [1., 1.]);
}

#[test]
fn directions_first_four_directions() {
    let mut south = state("south", 1, 2);
    south.delays = vec![5., 6.];
    let states = [south, state("north", 4, 1), state("east", 1, 3)];
    let plan = combine_plan(&states, CombineLayout::DirectionsFirst, 4, false).unwrap();
    assert_eq!((plan.dirs, plan.frame_count), (4, 3));
    #[rustfmt::skip]
    assert_eq!(sources(&plan), [
        // S from state 0, N from state 1's north, E and W from the last state.
        (0, 0), (1, 1), (2, 0), (2, 0),
        (0, 1), (1, 1), (2, 1), (2, 1),
        // Shorter states repeat their last frame.
        (0, 1), (1, 1), (2, 2), (2, 2),
    ]);
    // The first state's delays, 1 past its end.
    assert_eq!(plan.delays, [5., 6., 1.]);
}

#[test]
fn directions_first_eight_directions() {
    let states = [state("a", 8, 2), state("b", 1, 1)];
    let plan = combine_plan(&states, CombineLayout::DirectionsFirst, 8, false).unwrap();
    assert_eq!((plan.dirs, plan.frame_count), (8, 2));
    #[rustfmt::skip]
    assert_eq!(sources(&plan), [
        (0, 0), (1, 0), (1, 0), (1, 0), (1, 0), (1, 0), (1, 0), (1, 0),
        (0, 8), (1, 0), (1, 0), (1, 0), (1, 0), (1, 0), (1, 0), (1, 0),
    ]);

    let plan = combine_plan(&states, CombineLayout::DirectionsFirst, 8, true).unwrap();
    assert_eq!(plan.frame_count, 1);
    assert_eq!(plan.delays, [1.]);
}

#[test]
fn directions_first_frame_count_ignores_unused_states() {
    // With 4 directions, the fifth state is never used, so its frames don't count.
    let mut states: Vec<_> = (0..4).map(|i| state(&format!("s{i}"), 1, 1)).collect();
    states.push(state("unused", 1, 9));
    let plan = combine_plan(&states, CombineLayout::DirectionsFirst, 4, false).unwrap();
    assert_eq!(plan.frame_count, 1);
    assert_eq!(sources(&plan), [(0, 0), (1, 0), (2, 0), (3, 0)]);
}

#[test]
fn combine_plan_rejects_invalid_input() {
    let one = [state("a", 4, 1)];
    assert!(matches!(
        combine_plan(&one, CombineLayout::DirectionsFirst, 4, false),
        Err(DmiError::NotEnoughStates)
    ));
    assert!(matches!(
        combine_plan(&[], CombineLayout::FramesFirst, 1, false),
        Err(DmiError::NotEnoughStates)
    ));
    for dirs in [0, 9] {
        assert!(matches!(
            combine_plan(&one, CombineLayout::FramesFirst, dirs, false),
            Err(DmiError::InvalidDirections)
        ));
    }
    assert!(matches!(
        combine_plan(&[state("a", 1, 0)], CombineLayout::FramesFirst, 1, false),
        Err(DmiError::EmptyState)
    ));
}

#[test]
fn duplicate_copies_every_frame_under_a_new_key() {
    let temp = temp_dir("duplicate");
    let source = state("walk", 4, 2);
    write_frames(&temp, &source, 1);

    let copy = source.duplicate(&temp).unwrap();
    assert_eq!(copy.frame_key, "walk.2");
    assert_eq!(
        SerializedState {
            frame_key: source.frame_key.clone(),
            ..copy.clone()
        },
        source
    );
    assert_eq!(read_frames(&temp, &copy), read_frames(&temp, &source));
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn split_makes_one_state_per_direction() {
    let temp = temp_dir("split");
    let source = state("walk", 4, 2);
    write_frames(&temp, &source, 1);

    let states = source.split(&temp).unwrap();
    let names: Vec<_> = states.iter().map(|state| state.name.as_str()).collect();
    assert_eq!(names, ["walk - S", "walk - N", "walk - E", "walk - W"]);
    for (dir, state) in states.iter().enumerate() {
        assert_eq!((state.dirs, state.frame_count), (1, 2));
        assert_eq!(state.delays, source.delays);
        assert_eq!((state.loop_, state.rewind, state.movement), (2, true, true));
        assert!(state.hotspots.is_empty());
        // Frame f of direction d is the source's image f * dirs + d.
        let dir = dir as u8;
        assert_eq!(read_frames(&temp, state), [(1, dir), (1, 4 + dir)]);
    }

    let eight = state("eight", 8, 1);
    write_frames(&temp, &eight, 2);
    let names: Vec<_> = eight
        .split(&temp)
        .unwrap()
        .into_iter()
        .map(|state| state.name)
        .collect();
    assert_eq!(
        names,
        [
            "eight - S",
            "eight - N",
            "eight - E",
            "eight - W",
            "eight - SE",
            "eight - SW",
            "eight - NE",
            "eight - NW"
        ]
    );

    assert!(matches!(
        state("single", 1, 1).split(&temp),
        Err(DmiError::CannotSplit)
    ));
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn combine_copies_frames_by_the_plan() {
    let temp = temp_dir("combine");
    let states = [state("a", 4, 2), state("b", 1, 3)];
    write_frames(&temp, &states[0], 1);
    write_frames(&temp, &states[1], 2);

    for (layout, dirs, first_frame_only) in [
        (CombineLayout::FramesFirst, 1, false),
        (CombineLayout::FramesFirst, 4, false),
        (CombineLayout::FramesFirst, 8, true),
        (CombineLayout::DirectionsFirst, 4, false),
        (CombineLayout::DirectionsFirst, 8, true),
    ] {
        let plan = combine_plan(&states, layout, dirs, first_frame_only).unwrap();
        let combined = SerializedState::combine(
            &states,
            &temp,
            "both".to_string(),
            layout,
            dirs,
            first_frame_only,
        )
        .unwrap();
        assert_eq!(combined.name, "both");
        assert_eq!(
            (combined.dirs, combined.frame_count, &combined.delays),
            (plan.dirs, plan.frame_count, &plan.delays)
        );
        assert_eq!(
            (combined.loop_, combined.rewind, combined.movement),
            (0, false, false)
        );
        let expected: Vec<_> = plan
            .sources
            .iter()
            .map(|&(state, index)| (state as u8 + 1, index as u8))
            .collect();
        assert_eq!(read_frames(&temp, &combined), expected);
    }
    fs::remove_dir_all(temp).unwrap();
}

#[test]
fn failed_copy_leaves_no_frames_behind() {
    let temp = temp_dir("missing");
    let source = state("walk", 4, 2);
    write_frames(&temp, &source, 1);
    fs::remove_file(frame_file(&temp, &source.frame_key, 6)).unwrap();
    let before = frame_files(&temp);

    assert!(matches!(source.duplicate(&temp), Err(DmiError::Io(_))));
    assert_eq!(frame_files(&temp), before);
    // S and N split fine before E reaches the missing image; their frames are removed too.
    assert!(matches!(source.split(&temp), Err(DmiError::Io(_))));
    assert_eq!(frame_files(&temp), before);
    fs::remove_dir_all(temp).unwrap();
}
