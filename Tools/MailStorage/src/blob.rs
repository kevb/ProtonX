// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
//! Atomic SQLCipher containers for SDK-owned attachment and embedded MIME bytes.
//! This is not an export API: callers receive decrypted bytes only in memory.
use crate::{StorageError, key_connection};
use rusqlite::{Connection, OpenFlags};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub const MAX_BLOB: usize = 32 * 1024 * 1024;
const APPLICATION_ID: i64 = 0x50584231;

fn checked_file(path: &Path) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() > (MAX_BLOB + 1024 * 1024) as u64 {
        return Err(io::Error::from(io::ErrorKind::InvalidData));
    }
    Ok(())
}
fn failure(_: impl std::fmt::Debug) -> io::Error {
    // Never surface SQL statements, filenames or crypto details across IPC.
    io::Error::from(io::ErrorKind::InvalidData)
}

/// Atomic replacement: all temporary bytes and database pages are encrypted.
/// No plaintext temporary file or rollback journal is written.
pub fn write_blob(path: &Path, bytes: &[u8], key: &[u8; 32]) -> io::Result<()> {
    if bytes.len() > MAX_BLOB { return Err(io::Error::from(io::ErrorKind::InvalidInput)); }
    if fs::symlink_metadata(path).is_ok() { checked_file(path)?; }
    let parent = path.parent().ok_or(io::ErrorKind::InvalidInput)?;
    let temporary = tempfile::Builder::new().prefix(".protonx-blob-").tempfile_in(parent)?;
    let connection = Connection::open(temporary.path()).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 1"))?;
    key_connection(&connection, key).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 2"))?;
    connection.execute_batch("PRAGMA journal_mode=MEMORY; PRAGMA synchronous=FULL; CREATE TABLE content(id INTEGER PRIMARY KEY CHECK(id=1),bytes BLOB NOT NULL);").map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 3"))?;
    connection.pragma_update(None, "application_id", APPLICATION_ID).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 4"))?;
    connection.pragma_update(None, "user_version", 1).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 5"))?;
    connection.execute("INSERT INTO content VALUES(1,?1)", [bytes]).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 6"))?;
    drop(connection);
    temporary.as_file().sync_all()?;
    // Verify the whole encrypted payload before publishing it.
    if read_blob(temporary.path(), key).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob validation failed"))? != bytes { return Err(io::Error::from(io::ErrorKind::InvalidData)); }
    temporary.persist(path).map_err(|error| error.error)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

/// Wrong keys, malformed/oversized containers and plaintext files fail closed.
pub fn read_blob(path: &Path, key: &[u8; 32]) -> io::Result<Vec<u8>> {
    checked_file(path)?;
    // Check without following a terminal symlink. Ancestors must belong to the
    // locked/validated SDK profile, not an arbitrary user-selected export path.
    let _handle = OpenOptions::new().read(true).custom_flags(libc::O_NOFOLLOW).open(path)?;
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 7"))?;
    key_connection(&connection, key).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 8"))?;
    let application: i64 = connection.pragma_query_value(None, "application_id", |r| r.get(0)).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 9"))?;
    let version: i64 = connection.pragma_query_value(None, "user_version", |r| r.get(0)).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 10"))?;
    if application != APPLICATION_ID || version != 1 { return Err(io::Error::from(io::ErrorKind::InvalidData)); }
    let length: usize = connection.query_row("SELECT length(bytes) FROM content WHERE id=1", [], |r| r.get(0)).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 11"))?;
    if length > MAX_BLOB { return Err(io::Error::from(io::ErrorKind::InvalidData)); }
    connection.query_row("SELECT bytes FROM content WHERE id=1", [], |r| r.get(0)).map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "blob stage 12"))
}

/// SDK test fixtures run unkeyed unless a helper configures its key first. The
/// production secure helper always configures it before creating the SDK.
pub fn read_cached_file(path: &Path) -> io::Result<Vec<u8>> {
    match crate::encryption::database_key() {
        Some(key) => read_blob(path, key),
        None => fs::read(path),
    }
}
pub fn write_cached_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    match crate::encryption::database_key() {
        Some(key) => write_blob(path, bytes, key),
        None => Err(failure(StorageError::MissingKey)),
    }
}
pub fn cache_encryption_enabled() -> bool { crate::encryption::database_key().is_some() }
