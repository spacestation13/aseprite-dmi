//! Duplicate, split and combine states of a serialized DMI. Frame images live in its temp
//! directory as `{frame_key}.{index}.bytes`, with `index` = frame * dirs + dir.

use std::fs;
use std::path::Path;

use super::{DmiError, DmiResult, SerializedState, frame_key, frame_path};

/// Name suffixes of the states a split makes, in DMI direction order.
const DIRECTION_SUFFIXES: [&str; 8] = ["S", "N", "E", "W", "SE", "SW", "NE", "NW"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CombineLayout {
    /// Each state's frames follow the previous state's, with every direction per frame.
    /// A direction a state lacks repeats its first (south) one; extra directions are dropped.
    FramesFirst,
    /// Direction `d` comes from the `d`-th state (the last state fills the rest), as many frames
    /// as the longest of them; shorter ones repeat their last frame. Delays are the first state's.
    DirectionsFirst,
}

/// Layout of a combined state.
#[derive(Debug, PartialEq)]
pub struct CombinePlan {
    pub dirs: u32,
    pub frame_count: u32,
    pub delays: Vec<f32>,
    /// For each frame image of the combined state, in order: the index of its source state
    /// and the frame image index in that state.
    pub sources: Vec<(usize, u32)>,
}

/// Plans combining `states` into one state with `dirs` directions. `first_frame_only` uses
/// only the first frame of each state.
pub fn combine_plan(
    states: &[SerializedState],
    layout: CombineLayout,
    dirs: u32,
    first_frame_only: bool,
) -> DmiResult<CombinePlan> {
    if !(1..=8).contains(&dirs) {
        return Err(DmiError::InvalidDirections);
    }
    if states
        .iter()
        .any(|state| state.dirs == 0 || state.frame_count == 0)
    {
        return Err(DmiError::EmptyState);
    }
    let used_frames = |state: &SerializedState| {
        if first_frame_only {
            1
        } else {
            state.frame_count
        }
    };
    let delay = |state: &SerializedState, frame: u32| {
        state.delays.get(frame as usize).copied().unwrap_or(1.)
    };

    let mut sources = Vec::new();
    let mut delays = Vec::new();
    match layout {
        CombineLayout::FramesFirst => {
            if states.is_empty() {
                return Err(DmiError::NotEnoughStates);
            }
            for (index, state) in states.iter().enumerate() {
                for frame in 0..used_frames(state) {
                    for dir in 0..dirs {
                        let source_dir = if dir < state.dirs { dir } else { 0 };
                        sources.push((index, frame * state.dirs + source_dir));
                    }
                    delays.push(delay(state, frame));
                }
            }
        }
        CombineLayout::DirectionsFirst => {
            if states.len() < 2 {
                return Err(DmiError::NotEnoughStates);
            }
            let frame_count = states
                .iter()
                .take(dirs as usize)
                .map(used_frames)
                .max()
                .unwrap_or(1);
            for frame in 0..frame_count {
                for dir in 0..dirs {
                    let index = (dir as usize).min(states.len() - 1);
                    let state = &states[index];
                    let source_frame = frame.min(used_frames(state) - 1);
                    sources.push((index, source_frame * state.dirs + dir.min(state.dirs - 1)));
                }
                delays.push(delay(&states[0], frame));
            }
        }
    }

    Ok(CombinePlan {
        dirs,
        frame_count: (sources.len() / dirs as usize) as u32,
        delays,
        sources,
    })
}

impl SerializedState {
    /// Copies the state, frame images included, under a new frame key.
    pub fn duplicate(&self, temp: &Path) -> DmiResult<Self> {
        let frame_key = frame_key(temp, &self.name)?;
        let sources = (0..self.frame_count * self.dirs).map(|index| (&*self.frame_key, index));
        copy_frames(temp, &frame_key, sources)?;

        Ok(Self {
            frame_key,
            ..self.clone()
        })
    }

    /// Makes one single-direction state per direction, named `"{name} - {direction}"`.
    /// Hotspots are not kept.
    pub fn split(&self, temp: &Path) -> DmiResult<Vec<Self>> {
        if !(2..=8).contains(&self.dirs) {
            return Err(DmiError::CannotSplit);
        }
        if self.frame_count == 0 {
            return Err(DmiError::EmptyState);
        }

        let mut states: Vec<Self> = Vec::new();
        for (dir, suffix) in (0..self.dirs).zip(DIRECTION_SUFFIXES) {
            let name = format!("{} - {suffix}", self.name);
            let sources =
                (0..self.frame_count).map(|frame| (&*self.frame_key, frame * self.dirs + dir));
            let key = frame_key(temp, &name)
                .and_then(|key| copy_frames(temp, &key, sources).map(|()| key));
            let key = match key {
                Ok(key) => key,
                Err(err) => {
                    for state in &states {
                        remove_frames(temp, &state.frame_key, state.frame_count);
                    }
                    return Err(err);
                }
            };

            states.push(Self {
                name,
                dirs: 1,
                frame_key: key,
                frame_count: self.frame_count,
                delays: self.delays.clone(),
                loop_: self.loop_,
                rewind: self.rewind,
                movement: self.movement,
                hotspots: Vec::new(),
            });
        }

        Ok(states)
    }

    /// Combines `states` into a new state named `name`, laid out by [`combine_plan`].
    pub fn combine(
        states: &[Self],
        temp: &Path,
        name: String,
        layout: CombineLayout,
        dirs: u32,
        first_frame_only: bool,
    ) -> DmiResult<Self> {
        let plan = combine_plan(states, layout, dirs, first_frame_only)?;
        let frame_key = frame_key(temp, &name)?;
        let sources = plan
            .sources
            .iter()
            .map(|&(state, index)| (&*states[state].frame_key, index));
        copy_frames(temp, &frame_key, sources)?;

        Ok(Self {
            name,
            dirs: plan.dirs,
            frame_key,
            frame_count: plan.frame_count,
            delays: plan.delays,
            loop_: 0,
            rewind: false,
            movement: false,
            hotspots: Vec::new(),
        })
    }
}

/// Copies frame images into `frame_key`'s images 0, 1, ...; on failure removes the copies.
fn copy_frames<'a>(
    temp: &Path,
    frame_key: &str,
    sources: impl IntoIterator<Item = (&'a str, u32)>,
) -> DmiResult<()> {
    for (index, (source_key, source_index)) in (0_u32..).zip(sources) {
        let copy = fs::copy(
            frame_path(temp, source_key, source_index),
            frame_path(temp, frame_key, index),
        );
        if let Err(err) = copy {
            remove_frames(temp, frame_key, index + 1);
            return Err(err.into());
        }
    }
    Ok(())
}

fn remove_frames(temp: &Path, frame_key: &str, count: u32) {
    for index in 0..count {
        let _ = fs::remove_file(frame_path(temp, frame_key, index));
    }
}
