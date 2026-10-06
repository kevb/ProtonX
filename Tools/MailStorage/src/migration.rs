// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
//! Resumable database-set staging, not profile activation. Originals are retained.
//! No Keychain/network calls, attachment conversion or send queue replay occurs.
use crate::MIGRATION_DIRECTORY;
use crate::{ProfileGuard, StorageError, database_files, is_plaintext, validate_encrypted};
use rusqlite::{Connection, OpenFlags};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Component, Path, PathBuf};
use zeroize::Zeroizing;

const MAX_MANIFEST: u64 = 512 * 1024;
const MAX_DATABASES: usize = 128;
const MANIFEST: &str = "manifest.json";
const KEY_CHECK: &str = "key-check.db";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileState {
    suffix: String,
    bytes: u64,
    sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    relative: String,
    source: Vec<FileState>,
    staged: Option<FileState>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u32,
    prepared: bool,
    databases: Vec<Entry>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MigrationSummary {
    pub databases: usize,
    pub prepared: bool,
}

#[derive(Clone, Copy)]
#[cfg_attr(not(test), allow(dead_code))] // Indices are used by process-crash tests only.
enum Checkpoint {
    ManifestCreated,
    ExportDurable(usize),
    ProgressDurable(usize),
    Prepared,
}

/// Stage all discovered databases using SQLCipher export. Hold this guard for the
/// entire call. Resume after interruption with the same root and storage key.
///
/// A pending directory blocks both updated helper variants. A changed source,
/// missing/corrupt completed stage or wrong key fails closed; nothing is replaced
/// or erased. Even a prepared stage does NOT permit SDK startup or constitute a
/// usable encrypted profile. Cutover, attachments and real SDK send safety remain
/// separate activation gates. Never call this on a real account in this alpha.
pub fn stage_databases(
    guard: &ProfileGuard,
    key: &[u8; 32],
) -> Result<MigrationSummary, StorageError> {
    stage_with_checkpoints(guard, key, |_| {})
}

fn stage_with_checkpoints(
    guard: &ProfileGuard,
    key: &[u8; 32],
    mut checkpoint: impl FnMut(Checkpoint),
) -> Result<MigrationSummary, StorageError> {
    let root = guard.root();
    let directory = root.join(MIGRATION_DIRECTORY);
    let mut manifest = match fs::symlink_metadata(&directory) {
        Ok(metadata) => {
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err(StorageError::InvalidProfile);
            }
            load_manifest(&directory)?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // A format marker can denote a newer profile even if some database
            // files still have plaintext headers. Do not stage an unknown format.
            guard.check_startup(false)?;
            // Inspect/validate before leaving a persistent marker. Once created,
            // even an empty directory is a recovery gate, never an empty profile.
            let databases = database_files(root)?;
            if databases.is_empty() {
                return Err(StorageError::InvalidProfile);
            }
            let mut entries = Vec::with_capacity(databases.len());
            for path in databases {
                if !is_plaintext(&path)? {
                    return Err(StorageError::EncryptedProfile);
                }
                let relative = path
                    .strip_prefix(root)
                    .map_err(|_| StorageError::InvalidProfile)?
                    .to_str()
                    .ok_or(StorageError::InvalidProfile)?
                    .to_owned();
                validate_relative(&relative)?;
                entries.push(Entry {
                    relative,
                    source: source_state(&path)?,
                    staged: None,
                });
            }
            let value = Manifest {
                version: 1,
                prepared: false,
                databases: entries,
            };
            fs::DirBuilder::new()
                .mode(0o700)
                .create(&directory)
                .map_err(|_| StorageError::Unavailable)?;
            sync_directory(root)?;
            create_key_check(&directory, key)?;
            save_manifest(&directory, &value)?;
            checkpoint(Checkpoint::ManifestCreated);
            value
        }
        Err(_) => return Err(StorageError::Unavailable),
    };
    validate_manifest(&manifest)?;
    validate_stage_directory(&directory, manifest.databases.len())?;
    verify_key_check(&directory, key)?;
    verify_sources(root, &manifest)?;
    // Validate every already acknowledged file before making further progress.
    // A corrupt/missing completed stage is retained for explicit recovery, never
    // silently regenerated or passed to the SDK's corruption-reset behavior.
    for (index, entry) in manifest.databases.iter().enumerate() {
        if let Some(expected) = &entry.staged {
            verify_stage(&stage_path(&directory, index), expected, key)?;
        }
    }
    for index in 0..manifest.databases.len() {
        if manifest.databases[index].staged.is_some() {
            continue;
        }
        let source = checked_source(root, &manifest.databases[index].relative)?;
        let destination = stage_path(&directory, index);
        if let Ok(metadata) = fs::symlink_metadata(&destination) {
            if !metadata.is_file() || metadata.nlink() != 1 {
                return Err(StorageError::InvalidProfile);
            }
            // Crash after export but before progress acknowledgement: replace
            // only this reserved staging file from the unchanged source. Refuse
            // arbitrary plaintext/unknown output rather than overwriting it.
            if is_plaintext(&destination)? {
                return Err(StorageError::RecoveryRequired);
            }
        }
        if source_state(&source)? != manifest.databases[index].source {
            return Err(StorageError::SourceChanged);
        }
        export_database(&source, &destination, key)?;
        checkpoint(Checkpoint::ExportDurable(index));
        if source_state(&source)? != manifest.databases[index].source {
            return Err(StorageError::SourceChanged);
        }
        manifest.databases[index].staged = Some(file_state(&destination, "")?);
        save_manifest(&directory, &manifest)?;
        checkpoint(Checkpoint::ProgressDurable(index));
    }
    verify_sources(root, &manifest)?;
    if !manifest.prepared {
        manifest.prepared = true;
        save_manifest(&directory, &manifest)?;
        checkpoint(Checkpoint::Prepared);
    }
    Ok(MigrationSummary {
        databases: manifest.databases.len(),
        prepared: true,
    })
}

fn validate_relative(value: &str) -> Result<(), StorageError> {
    let path = Path::new(value);
    if value.len() > 1024
        || value.contains('\\')
        || path.components().collect::<PathBuf>().as_os_str() != path.as_os_str()
        || path
            .components()
            .any(|p| !matches!(p, Component::Normal(_)))
    {
        return Err(StorageError::InvalidProfile);
    }
    let mut components = path.components();
    if !matches!(components.next(), Some(Component::Normal(name)) if name == "sessions" || name == "users")
        || components.next().is_none()
        || !path.extension().is_some_and(|s| s == "db" || s == "sqlite")
    {
        return Err(StorageError::InvalidProfile);
    }
    Ok(())
}
fn validate_state(value: &FileState, staged: bool) -> Result<(), StorageError> {
    if value.bytes == 0
        || value.sha256.len() != 64
        || !value.sha256.bytes().all(|b| b.is_ascii_hexdigit())
        || (staged && !value.suffix.is_empty())
        || (!staged && !["", "-wal", "-journal"].contains(&value.suffix.as_str()))
    {
        return Err(StorageError::InvalidProfile);
    }
    Ok(())
}
fn validate_manifest(value: &Manifest) -> Result<(), StorageError> {
    if value.version != 1 || value.databases.is_empty() || value.databases.len() > MAX_DATABASES {
        return Err(StorageError::InvalidProfile);
    }
    let mut previous: Option<&str> = None;
    for entry in &value.databases {
        validate_relative(&entry.relative)?;
        if previous.is_some_and(|p| p >= entry.relative.as_str())
            || entry.source.is_empty()
            || entry.source.len() > 3
        {
            return Err(StorageError::InvalidProfile);
        }
        previous = Some(&entry.relative);
        let mut seen = std::collections::HashSet::new();
        for state in &entry.source {
            validate_state(state, false)?;
            if !seen.insert(&state.suffix) {
                return Err(StorageError::InvalidProfile);
            }
        }
        if entry.source[0].suffix != "" {
            return Err(StorageError::InvalidProfile);
        }
        if let Some(state) = &entry.staged {
            validate_state(state, true)?;
        }
        if value.prepared && entry.staged.is_none() {
            return Err(StorageError::InvalidProfile);
        }
    }
    Ok(())
}
fn checked_source(root: &Path, relative: &str) -> Result<PathBuf, StorageError> {
    validate_relative(relative)?;
    let mut current = root.to_owned();
    let components: Vec<_> = Path::new(relative).components().collect();
    for (index, part) in components.iter().enumerate() {
        current.push(part.as_os_str());
        let metadata = fs::symlink_metadata(&current).map_err(|_| StorageError::SourceChanged)?;
        if metadata.file_type().is_symlink()
            || (index + 1 < components.len() && !metadata.is_dir())
            || (index + 1 == components.len() && (!metadata.is_file() || metadata.nlink() != 1))
        {
            return Err(StorageError::InvalidProfile);
        }
    }
    Ok(current)
}
fn source_state(path: &Path) -> Result<Vec<FileState>, StorageError> {
    let mut output = vec![file_state(path, "")?];
    for suffix in ["-wal", "-journal", "-shm"] {
        let sidecar = PathBuf::from(format!(
            "{}{suffix}",
            path.to_str().ok_or(StorageError::InvalidProfile)?
        ));
        match fs::symlink_metadata(&sidecar) {
            Ok(metadata) => {
                if !metadata.is_file() || metadata.nlink() != 1 {
                    return Err(StorageError::InvalidProfile);
                }
                // SHM is an ephemeral WAL index; read marks may change even during
                // a read-only export. Data resides in the database and WAL.
                if suffix == "-shm" || metadata.len() == 0 {
                    continue;
                }
                if suffix == "-journal" {
                    return Err(StorageError::Busy);
                }
                output.push(file_state(&sidecar, suffix)?);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(StorageError::Unavailable),
        }
    }
    Ok(output)
}
fn verify_sources(root: &Path, value: &Manifest) -> Result<(), StorageError> {
    let discovered = database_files(root)?;
    let planned: Vec<_> = value
        .databases
        .iter()
        .map(|e| root.join(&e.relative))
        .collect();
    if discovered != planned {
        return Err(StorageError::SourceChanged);
    }
    for entry in &value.databases {
        let source = checked_source(root, &entry.relative)?;
        if source_state(&source)? != entry.source {
            return Err(StorageError::SourceChanged);
        }
    }
    Ok(())
}
fn stage_path(directory: &Path, index: usize) -> PathBuf {
    directory.join(format!("stage-{index:03}.db"))
}
fn file_state(path: &Path, suffix: &str) -> Result<FileState, StorageError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| StorageError::RecoveryRequired)?;
    if !metadata.is_file() || metadata.nlink() != 1 {
        return Err(StorageError::InvalidProfile);
    }
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| StorageError::Unavailable)?;
    let mut hash = Sha256::new();
    let mut buffer = Zeroizing::new([0_u8; 64 * 1024]);
    let mut bytes = 0;
    loop {
        let count = file
            .read(buffer.as_mut_slice())
            .map_err(|_| StorageError::Unavailable)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
        bytes += count as u64;
    }
    if bytes != metadata.len() {
        return Err(StorageError::SourceChanged);
    }
    Ok(FileState {
        suffix: suffix.to_owned(),
        bytes,
        sha256: format!("{:x}", hash.finalize()),
    })
}
fn verify_stage(path: &Path, expected: &FileState, key: &[u8; 32]) -> Result<(), StorageError> {
    if file_state(path, "")? != *expected {
        return Err(StorageError::RecoveryRequired);
    }
    validate_encrypted(path, key).map_err(|_| StorageError::RecoveryRequired)
}
fn load_manifest(directory: &Path) -> Result<Manifest, StorageError> {
    let path = directory.join(MANIFEST);
    let metadata = fs::symlink_metadata(&path).map_err(|_| StorageError::RecoveryRequired)?;
    if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > MAX_MANIFEST {
        return Err(StorageError::InvalidProfile);
    }
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| StorageError::Unavailable)?;
    serde_json::from_reader(file.take(MAX_MANIFEST + 1)).map_err(|_| StorageError::RecoveryRequired)
}
fn save_manifest(directory: &Path, value: &Manifest) -> Result<(), StorageError> {
    let path = directory.join(MANIFEST);
    if let Ok(metadata) = fs::symlink_metadata(&path) {
        if !metadata.is_file() || metadata.nlink() != 1 {
            return Err(StorageError::InvalidProfile);
        }
    }
    let mut temporary = tempfile::Builder::new()
        .prefix(".manifest-")
        .tempfile_in(directory)
        .map_err(|_| StorageError::Unavailable)?;
    serde_json::to_writer(&mut temporary, value).map_err(|_| StorageError::Unavailable)?;
    temporary
        .as_file()
        .sync_all()
        .map_err(|_| StorageError::Unavailable)?;
    temporary
        .persist(path)
        .map_err(|_| StorageError::Unavailable)?;
    sync_directory(directory)
}
fn sync_directory(path: &Path) -> Result<(), StorageError> {
    File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|_| StorageError::Unavailable)
}
fn validate_stage_directory(directory: &Path, count: usize) -> Result<(), StorageError> {
    let mut seen = 0;
    for child in fs::read_dir(directory).map_err(|_| StorageError::Unavailable)? {
        seen += 1;
        if seen > 512 {
            return Err(StorageError::InvalidProfile);
        }
        let child = child.map_err(|_| StorageError::Unavailable)?;
        let metadata = fs::symlink_metadata(child.path()).map_err(|_| StorageError::Unavailable)?;
        if !metadata.is_file() || metadata.nlink() != 1 {
            return Err(StorageError::InvalidProfile);
        }
        let name = child.file_name();
        let name = name.to_str().ok_or(StorageError::InvalidProfile)?;
        let reserved_stage = (0..count).any(|i| name == format!("stage-{i:03}.db"));
        if name != MANIFEST
            && name != KEY_CHECK
            && !reserved_stage
            && !name.starts_with(".export-")
            && !name.starts_with(".manifest-")
        {
            return Err(StorageError::InvalidProfile);
        }
    }
    // Interrupted temporary files remain untouched. They are not SDK inputs and
    // never justify removing originals or reporting that migration is activated.
    Ok(())
}

fn create_key_check(directory: &Path, key: &[u8; 32]) -> Result<(), StorageError> {
    let temporary = tempfile::Builder::new()
        .prefix(".export-")
        .tempfile_in(directory)
        .map_err(|_| StorageError::Unavailable)?;
    let connection = Connection::open(temporary.path()).map_err(|_| StorageError::Unavailable)?;
    crate::key_connection(&connection, key).map_err(|_| StorageError::Unavailable)?;
    connection.execute_batch("CREATE TABLE migration_format(version INTEGER NOT NULL); INSERT INTO migration_format VALUES(1);")
        .map_err(|_| StorageError::Unavailable)?;
    drop(connection);
    temporary
        .as_file()
        .sync_all()
        .map_err(|_| StorageError::Unavailable)?;
    temporary
        .persist(directory.join(KEY_CHECK))
        .map_err(|_| StorageError::Unavailable)?;
    sync_directory(directory)
}
fn verify_key_check(directory: &Path, key: &[u8; 32]) -> Result<(), StorageError> {
    let path = directory.join(KEY_CHECK);
    // Bind even an interrupted plan with zero completed exports to its initial
    // key. Never generate a replacement key or mix keys in one migration.
    let _ = file_state(&path, "")?;
    validate_encrypted(&path, key).map_err(|_| StorageError::RecoveryRequired)?;
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|_| StorageError::RecoveryRequired)?;
    crate::key_connection(&connection, key).map_err(|_| StorageError::RecoveryRequired)?;
    let version: i64 = connection
        .query_row("SELECT version FROM migration_format", [], |r| r.get(0))
        .map_err(|_| StorageError::RecoveryRequired)?;
    if version != 1 {
        return Err(StorageError::RecoveryRequired);
    }
    Ok(())
}

fn export_database(
    source_path: &Path,
    destination: &Path,
    key: &[u8; 32],
) -> Result<(), StorageError> {
    let directory = destination.parent().ok_or(StorageError::InvalidProfile)?;
    let temporary = tempfile::Builder::new()
        .prefix(".export-")
        .tempfile_in(directory)
        .map_err(|_| StorageError::Unavailable)?;
    // Make the encrypted destination main; attach the plaintext source with an
    // explicit read-only URI. A read-only main handle would make the destination
    // attachment read-only too. Check the actual source handle before export.
    let output = Connection::open_with_flags(
        temporary.path(),
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_CREATE
            | OpenFlags::SQLITE_OPEN_URI,
    )
    .map_err(|_| StorageError::Unavailable)?;
    crate::key_connection(&output, key).map_err(|_| StorageError::Unavailable)?;
    output
        .busy_timeout(std::time::Duration::ZERO)
        .map_err(|_| StorageError::Unavailable)?;
    output
        .execute(
            "ATTACH DATABASE ?1 AS source KEY ''",
            [read_only_uri(source_path)?],
        )
        .map_err(|_| StorageError::Unavailable)?;
    // SAFETY: the connection owns the handle; the C string is static. The
    // fail-closed check ensures SQLCipher/SQLite honored URI mode=ro.
    if unsafe { rusqlite::ffi::sqlite3_db_readonly(output.handle(), c"source".as_ptr()) } != 1 {
        return Err(StorageError::Unavailable);
    }
    let version: i64 = output
        .query_row("PRAGMA source.user_version", [], |r| r.get(0))
        .map_err(|_| StorageError::Unavailable)?;
    let application: i64 = output
        .query_row("PRAGMA source.application_id", [], |r| r.get(0))
        .map_err(|_| StorageError::Unavailable)?;
    let vacuum: i64 = output
        .query_row("PRAGMA source.auto_vacuum", [], |r| r.get(0))
        .map_err(|_| StorageError::Unavailable)?;
    let encoding: String = output
        .query_row("PRAGMA source.encoding", [], |r| r.get(0))
        .map_err(|_| StorageError::Unavailable)?;
    output
        .pragma_update(None, "auto_vacuum", vacuum)
        .map_err(|_| StorageError::Unavailable)?;
    output
        .pragma_update(None, "encoding", encoding)
        .map_err(|_| StorageError::Unavailable)?;
    output
        .execute_batch("BEGIN;")
        .map_err(|_| StorageError::Busy)?;
    let check: String = output
        .query_row("PRAGMA source.quick_check", [], |r| r.get(0))
        .map_err(|_| StorageError::Unavailable)?;
    if check != "ok" {
        return Err(StorageError::Unavailable);
    }
    output
        .query_row("SELECT sqlcipher_export('main', 'source')", [], |_| Ok(()))
        .map_err(|_| StorageError::Unavailable)?;
    output
        .pragma_update(None, "user_version", version)
        .map_err(|_| StorageError::Unavailable)?;
    output
        .pragma_update(None, "application_id", application)
        .map_err(|_| StorageError::Unavailable)?;
    output
        .execute_batch("COMMIT; DETACH DATABASE source;")
        .map_err(|_| StorageError::Unavailable)?;
    drop(output);
    validate_encrypted(temporary.path(), key)?;
    temporary
        .as_file()
        .sync_all()
        .map_err(|_| StorageError::Unavailable)?;
    temporary
        .persist(destination)
        .map_err(|_| StorageError::Unavailable)?;
    sync_directory(directory)
}

fn read_only_uri(path: &Path) -> Result<String, StorageError> {
    use std::fmt::Write as _;
    use std::os::unix::ffi::OsStrExt;
    let absolute = fs::canonicalize(path).map_err(|_| StorageError::Unavailable)?;
    let mut uri = String::from("file:");
    for byte in absolute.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || b"/-._~".contains(byte) {
            uri.push(*byte as char);
        } else {
            write!(&mut uri, "%{byte:02X}").map_err(|_| StorageError::Unavailable)?;
        }
    }
    uri.push_str("?mode=ro");
    Ok(uri)
}

#[cfg(test)]
mod tests;
