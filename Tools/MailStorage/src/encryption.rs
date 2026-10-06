// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// SQLCipher owns database encryption. No account cryptography is implemented here.
use crate::{StorageError, is_plaintext};
use rusqlite::{Connection, OpenFlags, ffi};
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use zeroize::Zeroizing;

static DATABASE_KEY: OnceLock<Zeroizing<[u8; 32]>> = OnceLock::new();

pub(crate) fn database_key() -> Option<&'static [u8; 32]> { DATABASE_KEY.get().map(|key| &**key) }

/// One isolated helper/profile per process. Configure before opening the SDK.
/// The SDK feature is opt-in; public upstream tests retain unkeyed databases.
pub fn configure_database_key(key: [u8; 32]) -> Result<(), StorageError> {
    DATABASE_KEY
        .set(Zeroizing::new(key))
        .map_err(|_| StorageError::Unavailable)
}

/// Called on every SDK read/write connection before any database statement.
pub fn initialize_sdk_connection(connection: &Connection) -> rusqlite::Result<()> {
    if let Some(key) = DATABASE_KEY.get() {
        key_connection(connection, key)?;
    }
    Ok(())
}

pub fn key_connection(connection: &Connection, key: &[u8; 32]) -> rusqlite::Result<()> {
    // Raw SQLCipher key syntax avoids a password KDF for a random 256-bit key.
    // Pass it through the C API, never through a logged SQL statement.
    let mut encoded = Zeroizing::new([0_u8; 67]);
    encoded[0] = b'x';
    encoded[1] = b'\'';
    encoded[66] = b'\'';
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for (i, byte) in key.iter().enumerate() {
        encoded[2 + i * 2] = HEX[(byte >> 4) as usize];
        encoded[3 + i * 2] = HEX[(byte & 15) as usize];
    }
    // SAFETY: the live connection owns this handle and SQLCipher copies key bytes.
    let result = unsafe { ffi::sqlite3_key(connection.handle(), encoded.as_ptr().cast(), 67) };
    if result != ffi::SQLITE_OK {
        return Err(rusqlite::Error::SqliteFailure(
            ffi::Error::new(result),
            None,
        ));
    }
    let version: String = connection.query_row("PRAGMA cipher_version", [], |r| r.get(0))?;
    if version.is_empty() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    connection.execute_batch("PRAGMA temp_store = MEMORY;")?;
    Ok(())
}

/// Validate before calling an SDK that may otherwise rename/rebuild corrupt DBs.
pub fn validate_encrypted(path: &Path, key: &[u8; 32]) -> Result<(), StorageError> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|_| StorageError::Unavailable)?;
    key_connection(&connection, key).map_err(|_| StorageError::Unavailable)?;
    connection
        .query_row("SELECT count(*) FROM sqlite_master", [], |r| {
            r.get::<_, i64>(0)
        })
        .map_err(|_| StorageError::Unavailable)?;
    let mut statement = connection
        .prepare("PRAGMA cipher_integrity_check")
        .map_err(|_| StorageError::Unavailable)?;
    let mut rows = statement.query([]).map_err(|_| StorageError::Unavailable)?;
    if rows
        .next()
        .map_err(|_| StorageError::Unavailable)?
        .is_some()
    {
        return Err(StorageError::Unavailable);
    }
    Ok(())
}

/// Explicit, restartable per-file conversion. The source is replaced only after
/// export, integrity validation and fsync; failed exports preserve the source.
/// Call only with all older app/helper processes closed and ProfileGuard held.
pub fn upgrade_database(path: &Path, key: &[u8; 32]) -> Result<(), StorageError> {
    if !fs::symlink_metadata(path)
        .map_err(|_| StorageError::Unavailable)?
        .is_file()
    {
        return Err(StorageError::InvalidProfile);
    }
    if !is_plaintext(path)? {
        return validate_encrypted(path, key);
    }
    let parent = path.parent().ok_or(StorageError::InvalidProfile)?;
    let stage = tempfile::Builder::new()
        .prefix(".protonx-encrypted-")
        .tempfile_in(parent)
        .map_err(|_| StorageError::Unavailable)?;
    let source = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|_| StorageError::Unavailable)?;
    source
        .busy_timeout(std::time::Duration::ZERO)
        .map_err(|_| StorageError::Unavailable)?;
    let busy: i64 = source
        .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| r.get(0))
        .map_err(|_| StorageError::Busy)?;
    if busy != 0 {
        return Err(StorageError::Busy);
    }
    let version: i64 = source
        .query_row("PRAGMA user_version", [], |r| r.get(0))
        .map_err(|_| StorageError::Unavailable)?;
    let application: i64 = source
        .query_row("PRAGMA application_id", [], |r| r.get(0))
        .map_err(|_| StorageError::Unavailable)?;
    // SQLCipher accepts the same raw-key syntax in a bound ATTACH argument.
    let mut attach_key = Zeroizing::new(String::from("x'"));
    use std::fmt::Write as _;
    for byte in key {
        write!(&mut *attach_key, "{byte:02x}").map_err(|_| StorageError::Unavailable)?;
    }
    attach_key.push('\'');
    source
        .execute(
            "ATTACH DATABASE ?1 AS encrypted KEY ?2",
            rusqlite::params![
                stage.path().to_str().ok_or(StorageError::InvalidProfile)?,
                attach_key.as_str()
            ],
        )
        .map_err(|_| StorageError::Unavailable)?;
    source
        .execute_batch("BEGIN EXCLUSIVE;")
        .map_err(|_| StorageError::Busy)?;
    source
        .query_row("SELECT sqlcipher_export('encrypted')", [], |_| Ok(()))
        .map_err(|_| StorageError::Unavailable)?;
    source
        .pragma_update(Some("encrypted"), "user_version", version)
        .map_err(|_| StorageError::Unavailable)?;
    source
        .pragma_update(Some("encrypted"), "application_id", application)
        .map_err(|_| StorageError::Unavailable)?;
    source
        .execute_batch("COMMIT; DETACH DATABASE encrypted;")
        .map_err(|_| StorageError::Unavailable)?;
    validate_encrypted(stage.path(), key)?;
    stage
        .as_file()
        .sync_all()
        .map_err(|_| StorageError::Unavailable)?;
    drop(source);
    // Checkpointed sidecars must not be replayed against the new database.
    for suffix in ["-wal", "-shm", "-journal"] {
        let sidecar = PathBuf::from(format!("{}{suffix}", path.to_string_lossy()));
        if sidecar.exists() {
            fs::remove_file(sidecar).map_err(|_| StorageError::Unavailable)?;
        }
    }
    stage.persist(path).map_err(|_| StorageError::Unavailable)?;
    File::open(parent)
        .and_then(|d| d.sync_all())
        .map_err(|_| StorageError::Unavailable)?;
    Ok(())
}
