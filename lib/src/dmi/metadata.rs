use super::{Dmi, DmiError, DmiResult, State};

const DMI_VERSION: &str = "4.0";

impl Dmi {
    pub fn set_metadata(&mut self, metadata: &str) -> DmiResult<()> {
        let mut lines = metadata.lines();

        if lines.next().ok_or(DmiError::MissingMetadataHeader)? != "# BEGIN DMI" {
            return Err(DmiError::MissingMetadataHeader);
        }

        if lines.next().ok_or(DmiError::InvalidMetadataVersion)?
            != format!("version = {DMI_VERSION}")
        {
            return Err(DmiError::InvalidMetadataVersion);
        }

        for line in lines {
            if line == "# END DMI" {
                break;
            }

            let mut split = line.trim().split(" = ");
            let (key, value) = (
                split.next().ok_or(DmiError::MissingMetadataValue)?,
                split.next().ok_or(DmiError::MissingMetadataValue)?,
            );

            match key {
                "width" => self.width = value.parse()?,
                "height" => self.height = value.parse()?,
                "state" => self.states.push(State::new(value.trim_matches('"').into())),
                "dirs" => {
                    self.states
                        .last_mut()
                        .ok_or(DmiError::OutOfOrderStateInfo)?
                        .dirs = value.parse()?;
                }
                "frames" => {
                    self.states
                        .last_mut()
                        .ok_or(DmiError::OutOfOrderStateInfo)?
                        .frame_count = value.parse()?;
                }
                "delay" => {
                    self.states
                        .last_mut()
                        .ok_or(DmiError::OutOfOrderStateInfo)?
                        .delays = value
                        .split(',')
                        .map(|delay| delay.parse())
                        .collect::<Result<_, _>>()?;
                }
                "loop" => {
                    self.states
                        .last_mut()
                        .ok_or(DmiError::OutOfOrderStateInfo)?
                        .loop_ = value.parse()?;
                }
                "rewind" => {
                    self.states
                        .last_mut()
                        .ok_or(DmiError::OutOfOrderStateInfo)?
                        .rewind = value == "1";
                }
                "movement" => {
                    self.states
                        .last_mut()
                        .ok_or(DmiError::OutOfOrderStateInfo)?
                        .movement = value == "1";
                }
                "hotspot" => {
                    self.states
                        .last_mut()
                        .ok_or(DmiError::OutOfOrderStateInfo)?
                        .hotspots
                        .push(value.into());
                }
                _ => return Err(DmiError::UnknownMetadataKey),
            }
        }

        Ok(())
    }

    pub fn get_metadata(&self) -> String {
        let mut metadata = String::from("# BEGIN DMI\n");
        metadata.push_str(&format!("version = {DMI_VERSION}\n"));
        metadata.push_str(&format!("\twidth = {}\n", self.width));
        metadata.push_str(&format!("\theight = {}\n", self.height));

        for state in &self.states {
            metadata.push_str(&format!("state = \"{}\"\n", state.name));
            metadata.push_str(&format!("\tdirs = {}\n", state.dirs));
            metadata.push_str(&format!("\tframes = {}\n", state.frame_count));
            if !state.delays.is_empty() {
                let delays = state
                    .delays
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(",");
                metadata.push_str(&format!("\tdelay = {delays}\n"));
            }
            if state.loop_ > 0 {
                metadata.push_str(&format!("\tloop = {}\n", state.loop_));
            }
            if state.rewind {
                metadata.push_str("\trewind = 1\n");
            }
            if state.movement {
                metadata.push_str("\tmovement = 1\n");
            }
            for hotspot in &state.hotspots {
                metadata.push_str(&format!("\thotspot = {hotspot}\n"));
            }
        }

        metadata.push_str("# END DMI\n");
        metadata
    }
}
