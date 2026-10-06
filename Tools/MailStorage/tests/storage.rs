// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
use protonx_mail_storage::{
    ProfileGuard, StorageError, database_files, is_plaintext, key_connection, upgrade_database,
    validate_encrypted,
};
use rusqlite::Connection;
use std::fs;
use std::os::unix::fs::symlink;
const KEY: [u8; 32] = [0x51; 32]; // Synthetic, never a real profile key.
const MARKER: &str = "PROTONX-SYNTHETIC-ENCRYPTED-STORAGE-CONTENT";

fn seed(connection: &Connection) {
    connection.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE body(value TEXT); CREATE TABLE send_queue(id INTEGER PRIMARY KEY, state TEXT); PRAGMA user_version=17; PRAGMA application_id=23;").unwrap();
    connection
        .execute("INSERT INTO body VALUES (?1)", [MARKER])
        .unwrap();
    connection
        .execute("INSERT INTO send_queue VALUES(1,'ambiguous')", [])
        .unwrap();
}
fn assert_no_marker(root: &std::path::Path) {
    for file in fs::read_dir(root).unwrap() {
        let file = file.unwrap().path();
        if file.is_file() {
            let data = fs::read(file).unwrap();
            assert!(!data.windows(MARKER.len()).any(|b| b == MARKER.as_bytes()));
        }
    }
}

#[test]
fn encrypted_database_and_wal_reject_missing_and_wrong_keys() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mail.db");
    let connection = Connection::open(&path).unwrap();
    key_connection(&connection, &KEY).unwrap();
    seed(&connection);
    assert!(!is_plaintext(&path).unwrap());
    assert_no_marker(directory.path());
    let unkeyed = Connection::open(&path).unwrap();
    assert!(
        unkeyed
            .query_row("SELECT value FROM body", [], |r| r.get::<_, String>(0))
            .is_err()
    );
    let wrong = Connection::open(&path).unwrap();
    key_connection(&wrong, &[0x99; 32]).unwrap();
    assert!(
        wrong
            .query_row("SELECT value FROM body", [], |r| r.get::<_, String>(0))
            .is_err()
    );
    drop(wrong);
    drop(unkeyed);
    drop(connection);
    validate_encrypted(&path, &KEY).unwrap();
    let reopened = Connection::open(&path).unwrap();
    key_connection(&reopened, &KEY).unwrap();
    assert_eq!(
        reopened
            .query_row("SELECT value FROM body", [], |r| r.get::<_, String>(0))
            .unwrap(),
        MARKER
    );
    assert_no_marker(directory.path());
}

#[test]
fn upgrade_preserves_body_queue_schema_and_is_restartable() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mail.db");
    let original = Connection::open(&path).unwrap();
    seed(&original);
    drop(original);
    assert!(is_plaintext(&path).unwrap());
    upgrade_database(&path, &KEY).unwrap();
    assert!(!is_plaintext(&path).unwrap());
    assert_no_marker(directory.path());
    upgrade_database(&path, &KEY).unwrap(); // Already encrypted: validation, no second export.
    let connection = Connection::open(&path).unwrap();
    key_connection(&connection, &KEY).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT value FROM body", [], |r| r.get::<_, String>(0))
            .unwrap(),
        MARKER
    );
    assert_eq!(
        connection
            .query_row("SELECT state FROM send_queue", [], |r| r
                .get::<_, String>(0))
            .unwrap(),
        "ambiguous"
    );
    assert_eq!(
        connection
            .query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        17
    );
    assert_eq!(
        connection
            .query_row("PRAGMA application_id", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        23
    );
}

#[test]
fn locked_database_upgrade_preserves_source() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mail.db");
    let original = Connection::open(&path).unwrap();
    seed(&original);
    original
        .execute_batch("BEGIN IMMEDIATE; INSERT INTO send_queue VALUES(2,'pending');")
        .unwrap();
    assert_eq!(upgrade_database(&path, &KEY), Err(StorageError::Busy));
    original.execute_batch("ROLLBACK;").unwrap();
    assert!(is_plaintext(&path).unwrap());
    assert_eq!(
        original
            .query_row("SELECT value FROM body", [], |r| r.get::<_, String>(0))
            .unwrap(),
        MARKER
    );
}

#[test]
fn corruption_and_wrong_key_never_rebuild_or_replace_existing_files() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mail.db");
    let original = Connection::open(&path).unwrap();
    key_connection(&original, &KEY).unwrap();
    seed(&original);
    drop(original);
    let bytes = fs::read(&path).unwrap();
    assert!(upgrade_database(&path, &[0x99; 32]).is_err());
    assert_eq!(fs::read(&path).unwrap(), bytes);
    let mut damaged = bytes;
    damaged[128] ^= 0xff;
    fs::write(&path, &damaged).unwrap();
    assert!(validate_encrypted(&path, &KEY).is_err());
    assert_eq!(fs::read(&path).unwrap(), damaged);
}

#[test]
fn profile_lock_and_path_discovery_reject_parallel_helpers_and_symlinks() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let guard = ProfileGuard::acquire(root).unwrap();
    assert!(matches!(
        ProfileGuard::acquire(root),
        Err(StorageError::Busy)
    ));
    fs::create_dir(root.join("sessions")).unwrap();
    fs::write(root.join("sessions/account.db"), b"synthetic").unwrap();
    assert_eq!(database_files(root).unwrap().len(), 1);
    symlink(root.join("sessions"), root.join("users")).unwrap();
    assert_eq!(database_files(root), Err(StorageError::InvalidProfile));
    drop(guard);
    assert!(ProfileGuard::acquire(root).is_ok());
}

#[test]
fn truncated_files_and_symlink_upgrade_are_refused_without_replacing_files() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mail.db");
    fs::write(&path, b"short").unwrap();
    assert!(upgrade_database(&path, &KEY).is_err());
    assert_eq!(fs::read(&path).unwrap(), b"short");
    let link = directory.path().join("link.db");
    symlink(&path, &link).unwrap();
    assert!(upgrade_database(&link, &KEY).is_err());
    assert!(
        fs::symlink_metadata(&link)
            .unwrap()
            .file_type()
            .is_symlink()
    );
}
