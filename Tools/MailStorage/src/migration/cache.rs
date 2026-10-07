// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
//! Existing attachment/MIME staging. Original files and SDK database paths stay
//! untouched; the encrypted plan records relative source paths for later rebasing.
use super::{FileState, file_state, stage_databases, sync_directory};
use crate::{
    MAX_BLOB, MIGRATION_DIRECTORY, ProfileGuard, StorageError, attachment_files, read_blob,
    write_blob,
};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use zeroize::Zeroizing;

pub(super) const DIRECTORY: &str = "attachment-stage";
const PLAN: &str = "plan.pxb";
const MAX_FILES: usize = 4096;
const MAX_PLAN: usize = 8 * 1024 * 1024;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    relative: String,
    source: FileState,
    staged: Option<FileState>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    version: u32,
    prepared: bool,
    files: Vec<Entry>,
}
#[derive(Debug, PartialEq, Eq)]
pub struct AttachmentMigrationSummary {
    pub files: usize,
    pub prepared: bool,
}
#[derive(Clone, Copy)]
#[cfg_attr(not(test), allow(dead_code))]
enum Checkpoint {
    Plan,
    Export(usize),
    Progress(usize),
    Prepared,
}

/// Prepare databases and encrypted attachment copies under the held profile lock.
/// Resume requires unchanged original files/databases and the same in-memory key.
/// Filenames and the source-to-stage map are encrypted, not in a plaintext manifest.
/// This is staging only: no SDK paths are updated, files deleted, profile activated,
/// Keychain requested or network/queue dispatched. Synthetic profiles only for now.
pub fn stage_attachment_cache(
    guard: &ProfileGuard,
    key: &[u8; 32],
) -> Result<AttachmentMigrationSummary, StorageError> {
    stage_with_checkpoints(guard, key, |_| {})
}

fn stage_with_checkpoints(
    guard: &ProfileGuard,
    key: &[u8; 32],
    mut checkpoint: impl FnMut(Checkpoint),
) -> Result<AttachmentMigrationSummary, StorageError> {
    stage_databases(guard, key)?; // Verify the database set and original key first.
    let root = guard.root();
    let parent = root.join(MIGRATION_DIRECTORY);
    let directory = parent.join(DIRECTORY);
    let mut plan = match fs::symlink_metadata(&directory) {
        Ok(_) => {
            validate_directory(&directory)?;
            let bytes = Zeroizing::new(
                read_blob(&directory.join(PLAN), key)
                    .map_err(|_| StorageError::RecoveryRequired)?,
            );
            if bytes.len() > MAX_PLAN {
                return Err(StorageError::InvalidProfile);
            }
            serde_json::from_slice::<Plan>(&bytes).map_err(|_| StorageError::RecoveryRequired)?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let mut files = vec![];
            for path in attachment_files(root)? {
                let relative = path
                    .strip_prefix(root)
                    .map_err(|_| StorageError::InvalidProfile)?
                    .to_str()
                    .ok_or(StorageError::InvalidProfile)?
                    .to_owned();
                checked_source(root, &relative)?;
                files.push(Entry {
                    relative,
                    source: file_state(&path, "")?,
                    staged: None,
                });
            }
            let value = Plan {
                version: 1,
                prepared: false,
                files,
            };
            validate_plan(&value)?;
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .map_err(|_| StorageError::Unavailable)?;
            sync_directory(&parent)?;
            save_plan(&directory, &value, key)?;
            checkpoint(Checkpoint::Plan);
            value
        }
        Err(_) => return Err(StorageError::Unavailable),
    };
    validate_plan(&plan)?;
    // Reserved names beyond the encrypted plan are never valid inputs for a
    // later cutover. Retain them and stop rather than silently ignoring them.
    for child in fs::read_dir(&directory).map_err(|_| StorageError::Unavailable)? {
        let name = child.map_err(|_| StorageError::Unavailable)?.file_name();
        let name = name.to_str().ok_or(StorageError::InvalidProfile)?;
        if asset_index(name).is_some_and(|i| i >= plan.files.len()) {
            return Err(StorageError::InvalidProfile);
        }
    }
    verify_sources(root, &plan)?;
    for (index, entry) in plan.files.iter().enumerate() {
        if let Some(expected) = &entry.staged {
            verify_stage(&asset_path(&directory, index), expected, &entry.source, key)?;
        }
    }
    for index in 0..plan.files.len() {
        if plan.files[index].staged.is_some() {
            continue;
        }
        let entry = &plan.files[index];
        let source = checked_source(root, &entry.relative)?;
        if file_state(&source, "")? != entry.source {
            return Err(StorageError::SourceChanged);
        }
        let destination = asset_path(&directory, index);
        // A published but unacknowledged container may be recreated after a crash;
        // never overwrite unknown/plaintext/corrupt reserved output.
        if fs::symlink_metadata(&destination).is_ok() {
            let bytes = Zeroizing::new(
                read_blob(&destination, key).map_err(|_| StorageError::RecoveryRequired)?,
            );
            verify_content(&bytes, &entry.source)?;
        } else {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&source)
                .map_err(|_| StorageError::Unavailable)?;
            let mut bytes = Zeroizing::new(Vec::new());
            file.take(MAX_BLOB as u64 + 1)
                .read_to_end(&mut bytes)
                .map_err(|_| StorageError::Unavailable)?;
            verify_content(&bytes, &entry.source)?;
            write_blob(&destination, &bytes, key).map_err(|_| StorageError::Unavailable)?;
        }
        checkpoint(Checkpoint::Export(index));
        if file_state(&source, "")? != entry.source {
            return Err(StorageError::SourceChanged);
        }
        plan.files[index].staged = Some(file_state(&destination, "")?);
        save_plan(&directory, &plan, key)?;
        checkpoint(Checkpoint::Progress(index));
    }
    verify_sources(root, &plan)?;
    stage_databases(guard, key)?; // Also refuse database mutations during cache work.
    if !plan.prepared {
        plan.prepared = true;
        save_plan(&directory, &plan, key)?;
        checkpoint(Checkpoint::Prepared);
    }
    Ok(AttachmentMigrationSummary {
        files: plan.files.len(),
        prepared: true,
    })
}

fn asset_path(directory: &Path, index: usize) -> PathBuf {
    directory.join(format!("asset-{index:04}.pxb"))
}
fn asset_index(name: &str) -> Option<usize> {
    let number = name.strip_prefix("asset-")?.strip_suffix(".pxb")?;
    if number.len() != 4 || !number.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    number.parse::<usize>().ok().filter(|i| *i < MAX_FILES)
}
fn checked_source(root: &Path, relative: &str) -> Result<PathBuf, StorageError> {
    let path = Path::new(relative);
    if relative.len() > 1024
        || relative.contains('\\')
        || path.components().collect::<PathBuf>().as_os_str() != path.as_os_str()
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
        || !path.starts_with("cache/attachments")
        || path.components().count() < 3
    {
        return Err(StorageError::InvalidProfile);
    }
    let mut current = root.to_owned();
    let components: Vec<_> = path.components().collect();
    for (index, part) in components.iter().enumerate() {
        current.push(part.as_os_str());
        let metadata = fs::symlink_metadata(&current).map_err(|_| StorageError::SourceChanged)?;
        if metadata.file_type().is_symlink()
            || (index + 1 < components.len() && !metadata.is_dir())
            || (index + 1 == components.len()
                && (!metadata.is_file()
                    || metadata.nlink() != 1
                    || metadata.len() > MAX_BLOB as u64))
        {
            return Err(StorageError::InvalidProfile);
        }
    }
    Ok(current)
}
fn valid_state(state: &FileState, encrypted: bool) -> bool {
    state.suffix.is_empty()
        && state.sha256.len() == 64
        && state.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        && if encrypted {
            state.bytes > 0 && state.bytes <= (MAX_BLOB + 1024 * 1024) as u64
        } else {
            state.bytes <= MAX_BLOB as u64
        }
}
fn validate_plan(plan: &Plan) -> Result<(), StorageError> {
    if plan.version != 1 || plan.files.len() > MAX_FILES {
        return Err(StorageError::InvalidProfile);
    }
    let mut previous: Option<&str> = None;
    for entry in &plan.files {
        // Path checking is repeated against the filesystem before every read.
        if previous.is_some_and(|p| p >= entry.relative.as_str())
            || !valid_state(&entry.source, false)
            || entry.staged.as_ref().is_some_and(|s| !valid_state(s, true))
            || (plan.prepared && entry.staged.is_none())
        {
            return Err(StorageError::InvalidProfile);
        }
        previous = Some(&entry.relative);
    }
    Ok(())
}
fn verify_sources(root: &Path, plan: &Plan) -> Result<(), StorageError> {
    let paths = attachment_files(root)?;
    let planned: Vec<_> = plan.files.iter().map(|e| root.join(&e.relative)).collect();
    if paths != planned {
        return Err(StorageError::SourceChanged);
    }
    for entry in &plan.files {
        let path = checked_source(root, &entry.relative)?;
        if file_state(&path, "")? != entry.source {
            return Err(StorageError::SourceChanged);
        }
    }
    Ok(())
}
fn verify_content(bytes: &[u8], expected: &FileState) -> Result<(), StorageError> {
    use sha2::{Digest, Sha256};
    if bytes.len() > MAX_BLOB
        || bytes.len() as u64 != expected.bytes
        || format!("{:x}", Sha256::digest(bytes)) != expected.sha256
    {
        return Err(StorageError::RecoveryRequired);
    }
    Ok(())
}
fn verify_stage(
    path: &Path,
    expected: &FileState,
    source: &FileState,
    key: &[u8; 32],
) -> Result<(), StorageError> {
    if file_state(path, "")? != *expected {
        return Err(StorageError::RecoveryRequired);
    }
    let bytes = Zeroizing::new(read_blob(path, key).map_err(|_| StorageError::RecoveryRequired)?);
    verify_content(&bytes, source)
}
fn save_plan(directory: &Path, plan: &Plan, key: &[u8; 32]) -> Result<(), StorageError> {
    let bytes = Zeroizing::new(serde_json::to_vec(plan).map_err(|_| StorageError::Unavailable)?);
    if bytes.len() > MAX_PLAN {
        return Err(StorageError::InvalidProfile);
    }
    write_blob(&directory.join(PLAN), &bytes, key).map_err(|_| StorageError::Unavailable)
}
pub(super) fn validate_directory(directory: &Path) -> Result<(), StorageError> {
    let metadata = fs::symlink_metadata(directory).map_err(|_| StorageError::Unavailable)?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.permissions().mode() & 0o777 != 0o700
    {
        return Err(StorageError::InvalidProfile);
    }
    for (index, entry) in fs::read_dir(directory)
        .map_err(|_| StorageError::Unavailable)?
        .enumerate()
    {
        if index >= MAX_FILES + 512 {
            return Err(StorageError::InvalidProfile);
        }
        let entry = entry.map_err(|_| StorageError::Unavailable)?;
        let metadata = fs::symlink_metadata(entry.path()).map_err(|_| StorageError::Unavailable)?;
        let name = entry.file_name();
        let name = name.to_str().ok_or(StorageError::InvalidProfile)?;
        let reserved = asset_index(name).is_some();
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.permissions().mode() & 0o777 != 0o600
            || (name != PLAN && !reserved && !name.starts_with(".protonx-blob-"))
        {
            return Err(StorageError::InvalidProfile);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests;
