//! Deterministic, in-memory backend for development without a WinOLS license.

use crate::domain::{MAX_MAPS, MAX_PAGE_SIZE, MapDefinition, MapList, MapRecord, ProjectInfo};

pub const MOCK_PROJECT_ID: &str = "mock-project";
pub const MOCK_PROJECT_SIZE: u64 = 1024 * 1024;

#[derive(Debug, Default)]
pub struct MockBackend {
    maps: Vec<MapRecord>,
}

impl MockBackend {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn project(&self) -> ProjectInfo {
        ProjectInfo {
            id: MOCK_PROJECT_ID.into(),
            name: "Synthetic WinOLS project (mock)".into(),
            size_bytes: MOCK_PROJECT_SIZE,
            map_count: self.maps.len() as u32,
        }
    }

    /// Return at most 100 records. `total` includes records outside this page.
    pub fn list_maps(&self, offset: u32, limit: u32) -> MapList {
        MapList {
            maps: self
                .maps
                .iter()
                .skip(offset as usize)
                .take(limit.min(MAX_PAGE_SIZE) as usize)
                .cloned()
                .collect(),
            total: self.maps.len() as u32,
        }
    }

    pub fn get_map(&self, id: &str) -> Result<MapRecord, String> {
        self.maps
            .iter()
            .find(|map| map.id == id)
            .cloned()
            .ok_or_else(|| format!("map not found: {id}"))
    }

    /// Validate all input and the expected project before creating a definition.
    pub fn create_map(
        &mut self,
        expected_project_id: &str,
        definition: MapDefinition,
    ) -> Result<MapRecord, String> {
        if expected_project_id != MOCK_PROJECT_ID {
            return Err(format!(
                "project mismatch: expected {expected_project_id}, active project is {MOCK_PROJECT_ID}"
            ));
        }
        definition.validate(MOCK_PROJECT_SIZE)?;
        if self.maps.len() >= MAX_MAPS {
            return Err(format!("project has reached the limit of {MAX_MAPS} maps"));
        }
        if self
            .maps
            .iter()
            .any(|map| map.definition.name == definition.name)
        {
            return Err(format!("a map named '{}' already exists", definition.name));
        }
        if self
            .maps
            .iter()
            .any(|map| map.definition.address == definition.address)
        {
            return Err(format!(
                "a map at byte address {} already exists",
                definition.address
            ));
        }
        let map = MapRecord {
            id: format!("mock-map-{}", self.maps.len() + 1),
            definition,
        };
        self.maps.push(map.clone());
        Ok(map)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{AxisDefinition, DataType};

    fn definition(name: &str, address: u64) -> MapDefinition {
        MapDefinition {
            name: name.into(),
            address,
            columns: 4,
            rows: 2,
            data_type: DataType::I16Be,
            factor: 0.25,
            offset: -40.0,
            unit: "C".into(),
            x_axis: Some(AxisDefinition {
                address: 512,
                data_type: DataType::U16Le,
                factor: 10.0,
                offset: 0.0,
                unit: "rpm".into(),
            }),
            y_axis: None,
        }
    }

    #[test]
    fn creates_and_reads_back_every_definition_property() {
        let mut backend = MockBackend::new();
        let definition = definition("Synthetic temperature", 128);
        let created = backend
            .create_map(MOCK_PROJECT_ID, definition.clone())
            .unwrap();
        assert_eq!(created.id, "mock-map-1");
        assert_eq!(created.definition, definition);
        assert_eq!(backend.get_map(&created.id).unwrap(), created);
        assert_eq!(backend.project().map_count, 1);
        assert_eq!(backend.project().size_bytes, MOCK_PROJECT_SIZE);
        assert_eq!(backend.list_maps(0, 10).maps, vec![created]);
    }

    #[test]
    fn project_mismatch_and_invalid_definition_never_create_a_map() {
        let mut backend = MockBackend::new();
        assert!(
            backend
                .create_map("another-project", definition("A", 0))
                .is_err()
        );
        assert!(
            backend
                .create_map(MOCK_PROJECT_ID, definition("A", MOCK_PROJECT_SIZE))
                .is_err()
        );
        assert_eq!(backend.project().map_count, 0);
        assert!(backend.get_map("mock-map-1").is_err());
        let created = backend
            .create_map(MOCK_PROJECT_ID, definition("A", 0))
            .unwrap();
        assert_eq!(created.id, "mock-map-1");
    }

    #[test]
    fn duplicate_name_or_address_does_not_mutate_existing_state() {
        let mut backend = MockBackend::new();
        let original = backend
            .create_map(MOCK_PROJECT_ID, definition("A", 0))
            .unwrap();
        assert!(
            backend
                .create_map(MOCK_PROJECT_ID, definition("A", 32))
                .is_err()
        );
        assert!(
            backend
                .create_map(MOCK_PROJECT_ID, definition("B", 0))
                .is_err()
        );
        assert_eq!(backend.list_maps(0, 100).maps, vec![original]);
        let second = backend
            .create_map(MOCK_PROJECT_ID, definition("B", 32))
            .unwrap();
        assert_eq!(second.id, "mock-map-2");
    }

    #[test]
    fn pagination_is_bounded_and_retains_total_count() {
        let mut backend = MockBackend::new();
        for index in 0..105 {
            backend
                .create_map(
                    MOCK_PROJECT_ID,
                    definition(&format!("Map {index}"), index * 16),
                )
                .unwrap();
        }
        let first = backend.list_maps(0, u32::MAX);
        assert_eq!(first.total, 105);
        assert_eq!(first.maps.len(), MAX_PAGE_SIZE as usize);
        let tail = backend.list_maps(100, 100);
        assert_eq!(tail.maps.len(), 5);
        assert_eq!(tail.maps[0].id, "mock-map-101");
        assert_eq!(tail.total, 105);
        assert!(backend.list_maps(u32::MAX, 100).maps.is_empty());
        assert!(backend.list_maps(0, 0).maps.is_empty());
    }
}
