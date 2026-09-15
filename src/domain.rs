//! Portable definitions shared by the MCP server and WinOLS bridge.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub const MAX_DIMENSION: u32 = 4096;
pub const MAX_MAP_ELEMENTS: u64 = 1_048_576;
pub const MAX_PAGE_SIZE: u32 = 100;
pub const MAX_MAPS: usize = 10_000;

fn default_factor() -> f64 {
    1.0
}

/// Integer storage type, including byte order for multibyte values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub enum DataType {
    #[serde(rename = "u8")]
    U8,
    #[serde(rename = "i8")]
    I8,
    #[serde(rename = "u16_le")]
    U16Le,
    #[serde(rename = "u16_be")]
    U16Be,
    #[serde(rename = "i16_le")]
    I16Le,
    #[serde(rename = "i16_be")]
    I16Be,
    #[serde(rename = "u32_le")]
    U32Le,
    #[serde(rename = "u32_be")]
    U32Be,
    #[serde(rename = "i32_le")]
    I32Le,
    #[serde(rename = "i32_be")]
    I32Be,
}

impl DataType {
    pub const fn byte_width(self) -> u64 {
        match self {
            Self::U8 | Self::I8 => 1,
            Self::U16Le | Self::U16Be | Self::I16Le | Self::I16Be => 2,
            Self::U32Le | Self::U32Be | Self::I32Le | Self::I32Be => 4,
        }
    }
}

/// A contiguous axis whose length is the map's columns (X) or rows (Y).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct AxisDefinition {
    /// Zero-based byte offset in the project binary.
    pub address: u64,
    pub data_type: DataType,
    /// Physical value = raw integer * factor + offset.
    #[serde(default = "default_factor")]
    pub factor: f64,
    #[serde(default)]
    pub offset: f64,
    #[serde(default)]
    pub unit: String,
}

/// A contiguous, row-major map definition. No binary data is changed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapDefinition {
    pub name: String,
    /// Zero-based byte offset in the project binary.
    pub address: u64,
    pub columns: u32,
    pub rows: u32,
    pub data_type: DataType,
    /// Physical value = raw integer * factor + offset.
    #[serde(default = "default_factor")]
    pub factor: f64,
    #[serde(default)]
    pub offset: f64,
    #[serde(default)]
    pub unit: String,
    #[serde(default)]
    pub x_axis: Option<AxisDefinition>,
    #[serde(default)]
    pub y_axis: Option<AxisDefinition>,
}

impl MapDefinition {
    /// Validate the complete definition before any backend mutation.
    pub fn validate(&self, project_size: u64) -> Result<(), String> {
        validate_text("name", &self.name, 128, true)?;
        validate_scaling("map", self.factor, self.offset, &self.unit)?;
        if self.columns == 0 || self.rows == 0 {
            return Err("columns and rows must both be at least 1".into());
        }
        if self.columns > MAX_DIMENSION || self.rows > MAX_DIMENSION {
            return Err(format!("columns and rows must not exceed {MAX_DIMENSION}"));
        }
        let cells = u64::from(self.columns)
            .checked_mul(u64::from(self.rows))
            .ok_or("map dimensions overflow")?;
        if cells > MAX_MAP_ELEMENTS {
            return Err(format!("map must not exceed {MAX_MAP_ELEMENTS} cells"));
        }
        validate_range("map", self.address, cells, self.data_type, project_size)?;
        for (label, axis, length) in [
            ("x_axis", &self.x_axis, self.columns),
            ("y_axis", &self.y_axis, self.rows),
        ] {
            if let Some(axis) = axis {
                validate_scaling(label, axis.factor, axis.offset, &axis.unit)?;
                validate_range(
                    label,
                    axis.address,
                    u64::from(length),
                    axis.data_type,
                    project_size,
                )?;
            }
        }
        Ok(())
    }
}

fn validate_text(label: &str, value: &str, max_chars: usize, required: bool) -> Result<(), String> {
    if required && value.trim().is_empty() {
        return Err(format!("{label} must not be empty or whitespace-only"));
    }
    if value.chars().count() > max_chars {
        return Err(format!("{label} must not exceed {max_chars} characters"));
    }
    if value.chars().any(char::is_control) {
        return Err(format!("{label} must not contain control characters"));
    }
    Ok(())
}

fn validate_scaling(label: &str, factor: f64, offset: f64, unit: &str) -> Result<(), String> {
    if !factor.is_finite() || factor == 0.0 {
        return Err(format!("{label} factor must be finite and nonzero"));
    }
    if !offset.is_finite() {
        return Err(format!("{label} offset must be finite"));
    }
    validate_text(&format!("{label} unit"), unit, 64, false)
}

fn validate_range(
    label: &str,
    address: u64,
    count: u64,
    data_type: DataType,
    project_size: u64,
) -> Result<(), String> {
    let bytes = count
        .checked_mul(data_type.byte_width())
        .ok_or_else(|| format!("{label} byte length overflow"))?;
    let end = address
        .checked_add(bytes)
        .ok_or_else(|| format!("{label} address range overflow"))?;
    if end > project_size {
        return Err(format!(
            "{label} byte range [{address}, {end}) exceeds project size {project_size}"
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapRecord {
    pub id: String,
    pub definition: MapDefinition,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProjectInfo {
    pub id: String,
    pub name: String,
    pub size_bytes: u64,
    pub map_count: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct MapList {
    pub maps: Vec<MapRecord>,
    pub total: u32,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn definition() -> MapDefinition {
        serde_json::from_value(serde_json::json!({
            "name": "Synthetic load", "address": 32, "columns": 4,
            "rows": 2, "data_type": "u16_le"
        }))
        .unwrap()
    }

    #[test]
    fn exact_binary_boundary_is_valid_but_one_byte_short_is_not() {
        let map = definition();
        assert!(map.validate(48).is_ok());
        assert!(
            map.validate(47)
                .unwrap_err()
                .contains("exceeds project size")
        );
        let mut overflowing = map;
        overflowing.address = u64::MAX - 7;
        assert!(
            overflowing
                .validate(u64::MAX)
                .unwrap_err()
                .contains("overflow")
        );
    }

    #[test]
    fn axes_use_the_correct_dimension_and_their_own_storage_width() {
        let mut map = definition();
        map.x_axis = Some(AxisDefinition {
            address: 100,
            data_type: DataType::U32Be,
            factor: 0.5,
            offset: -10.0,
            unit: "rpm".into(),
        });
        map.y_axis = Some(AxisDefinition {
            address: 114,
            data_type: DataType::U8,
            factor: 1.0,
            offset: 0.0,
            unit: String::new(),
        });
        assert!(map.validate(116).is_ok());
        assert!(map.validate(115).unwrap_err().starts_with("x_axis"));
        map.x_axis = None;
        assert!(map.validate(115).unwrap_err().starts_with("y_axis"));
    }

    #[test]
    fn invalid_dimensions_are_rejected() {
        for (columns, rows) in [(0, 1), (1, 0), (4097, 1), (1, 4097), (4096, 4096)] {
            let mut map = definition();
            map.columns = columns;
            map.rows = rows;
            assert!(map.validate(u64::MAX).is_err(), "{columns} x {rows}");
        }
    }

    #[test]
    fn invalid_names_units_and_scaling_are_rejected() {
        for name in [
            "".into(),
            " \t ".into(),
            "bad\nname".into(),
            "x".repeat(129),
        ] {
            let mut map = definition();
            map.name = name;
            assert!(map.validate(1024).is_err());
        }
        for factor in [0.0, -0.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut map = definition();
            map.factor = factor;
            assert!(map.validate(1024).is_err());
        }
        for offset in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut map = definition();
            map.offset = offset;
            assert!(map.validate(1024).is_err());
        }
        for unit in ["x".repeat(65), "rpm\0".into()] {
            let mut map = definition();
            map.unit = unit;
            assert!(map.validate(1024).is_err());
        }
    }

    #[test]
    fn explicit_storage_types_round_trip_and_ambiguous_types_are_rejected() {
        for (name, width) in [
            ("u8", 1),
            ("i8", 1),
            ("u16_le", 2),
            ("u16_be", 2),
            ("i16_le", 2),
            ("i16_be", 2),
            ("u32_le", 4),
            ("u32_be", 4),
            ("i32_le", 4),
            ("i32_be", 4),
        ] {
            let data_type: DataType = serde_json::from_value(serde_json::json!(name)).unwrap();
            assert_eq!(data_type.byte_width(), width);
            assert_eq!(serde_json::to_value(data_type).unwrap(), name);
        }
        for name in ["u16", "float32", "U16LE"] {
            assert!(serde_json::from_value::<DataType>(serde_json::json!(name)).is_err());
        }
    }

    #[test]
    fn defaults_are_identity_scaling_and_unknown_properties_are_errors() {
        let map = definition();
        assert_eq!(map.factor, 1.0);
        assert_eq!(map.offset, 0.0);
        assert_eq!(map.unit, "");
        assert_eq!(map.x_axis, None);
        let mut json = serde_json::to_value(map).unwrap();
        json["colums"] = serde_json::json!(4);
        assert!(serde_json::from_value::<MapDefinition>(json).is_err());
        assert!(
            serde_json::from_value::<AxisDefinition>(serde_json::json!({
                "address": 0, "data_type": "u8", "length": 4
            }))
            .is_err()
        );
    }

    #[test]
    fn axis_scaling_is_validated_as_well_as_map_scaling() {
        let mut map = definition();
        map.y_axis = Some(AxisDefinition {
            address: 0,
            data_type: DataType::I16Be,
            factor: f64::NAN,
            offset: 0.0,
            unit: String::new(),
        });
        assert!(map.validate(1024).unwrap_err().starts_with("y_axis factor"));
    }
}
