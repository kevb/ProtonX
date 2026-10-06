// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
use super::*;
use crate::{ENCRYPTED_FORMAT, FORMAT_FILE, key_connection};
use std::os::unix::fs::{PermissionsExt, symlink};
use std::process::Command;

const KEY: [u8; 32] = [0x65; 32]; // Public synthetic fixture; never read from Keychain.
const MARKER: &str = "PROTONX-SYNTHETIC-MIGRATION-DRAFT";

fn seed(path: &Path) -> Connection {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Connection::open(path).unwrap();
    db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; PRAGMA user_version=17; PRAGMA application_id=23; CREATE TABLE drafts(id INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT, state TEXT); CREATE INDEX draft_state ON drafts(state); CREATE VIEW pending AS SELECT * FROM drafts WHERE state='ambiguous'; CREATE TABLE counters(count INTEGER); INSERT INTO counters VALUES(0); CREATE TRIGGER draft_added AFTER INSERT ON drafts BEGIN UPDATE counters SET count=count+1; END;").unwrap();
    db.execute(
        "INSERT INTO drafts(body,state) VALUES(?1,'ambiguous')",
        [MARKER],
    )
    .unwrap();
    db
}
fn fixture(root: &Path) {
    drop(seed(&root.join("sessions/account.db")));
    drop(seed(&root.join("users/synthetic-user/mail.db")));
}
fn stages(root: &Path) -> Vec<PathBuf> {
    vec![
        root.join(MIGRATION_DIRECTORY).join("stage-000.db"),
        root.join(MIGRATION_DIRECTORY).join("stage-001.db"),
    ]
}
fn assert_preserved_and_prepared(root: &Path) {
    for (source, stage) in database_files(root).unwrap().iter().zip(stages(root)) {
        assert!(is_plaintext(source).unwrap());
        assert!(!is_plaintext(&stage).unwrap());
        let db = Connection::open(&stage).unwrap();
        key_connection(&db, &KEY).unwrap();
        assert_eq!(
            db.query_row("SELECT body FROM pending", [], |r| r.get::<_, String>(0))
                .unwrap(),
            MARKER
        );
        assert_eq!(
            db.query_row("SELECT state FROM pending", [], |r| r.get::<_, String>(0))
                .unwrap(),
            "ambiguous"
        );
        assert_eq!(
            db.query_row("PRAGMA user_version", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            17
        );
        assert_eq!(
            db.query_row("PRAGMA application_id", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            23
        );
        assert_eq!(
            db.query_row(
                "SELECT seq FROM sqlite_sequence WHERE name='drafts'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
        assert_eq!(
            db.query_row("SELECT count FROM counters", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            db.query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name='draft_added'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
    }
    for child in fs::read_dir(root.join(MIGRATION_DIRECTORY)).unwrap() {
        let path = child.unwrap().path();
        let bytes = fs::read(&path).unwrap();
        assert!(!bytes.windows(MARKER.len()).any(|b| b == MARKER.as_bytes()));
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert_eq!(
        fs::metadata(root.join(MIGRATION_DIRECTORY))
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o700
    );
}

#[test]
fn database_set_is_staged_without_replacing_originals_or_replaying_sends() {
    let root = tempfile::tempdir().unwrap();
    fixture(root.path());
    let originals: Vec<_> = database_files(root.path())
        .unwrap()
        .iter()
        .map(|p| fs::read(p).unwrap())
        .collect();
    let guard = ProfileGuard::acquire(root.path()).unwrap();
    assert_eq!(
        stage_databases(&guard, &KEY).unwrap(),
        MigrationSummary {
            databases: 2,
            prepared: true
        }
    );
    assert_preserved_and_prepared(root.path());
    assert_eq!(
        guard.check_startup(false),
        Err(StorageError::MigrationPending)
    );
    assert_eq!(
        guard.check_startup(true),
        Err(StorageError::MigrationPending)
    );
    assert_eq!(
        originals,
        database_files(root.path())
            .unwrap()
            .iter()
            .map(|p| fs::read(p).unwrap())
            .collect::<Vec<_>>()
    );
    let stage_bytes: Vec<_> = stages(root.path())
        .iter()
        .map(|p| fs::read(p).unwrap())
        .collect();
    stage_databases(&guard, &KEY).unwrap();
    assert_eq!(
        stage_bytes,
        stages(root.path())
            .iter()
            .map(|p| fs::read(p).unwrap())
            .collect::<Vec<_>>()
    );
}

#[test]
fn committed_wal_rows_are_included_without_forcing_source_checkpoint() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("sessions/account.db");
    let keeper = seed(&path); // Committed row lives in WAL while connection stays open.
    let before = source_state(&path).unwrap();
    assert!(before.iter().any(|s| s.suffix == "-wal"));
    let guard = ProfileGuard::acquire(root.path()).unwrap();
    stage_databases(&guard, &KEY).unwrap();
    assert_eq!(source_state(&path).unwrap(), before);
    let stage = stage_path(&root.path().join(MIGRATION_DIRECTORY), 0);
    let db = Connection::open(&stage).unwrap();
    key_connection(&db, &KEY).unwrap();
    assert_eq!(
        db.query_row("SELECT body FROM drafts", [], |r| r.get::<_, String>(0))
            .unwrap(),
        MARKER
    );
    drop(db);
    drop(keeper);
}

#[test]
fn wrong_key_is_refused_before_and_after_any_database_export() {
    for stop_after in ["manifest", "progress-0", "prepared"] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), stop_after);
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        let original = snapshot_files(root.path());
        assert_eq!(
            stage_databases(&guard, &[0x99; 32]),
            Err(StorageError::RecoveryRequired)
        );
        assert_eq!(snapshot_files(root.path()), original);
        stage_databases(&guard, &KEY).unwrap();
        assert_preserved_and_prepared(root.path());
    }
}

#[test]
fn killed_process_can_resume_at_every_durable_transition() {
    for point in [
        "manifest",
        "export-0",
        "progress-0",
        "export-1",
        "progress-1",
        "prepared",
    ] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), point);
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        // Process termination released its lock, but the durable marker still
        // blocks both normal and encrypted helper startup.
        assert_eq!(
            guard.check_startup(false),
            Err(StorageError::MigrationPending)
        );
        assert_eq!(
            guard.check_startup(true),
            Err(StorageError::MigrationPending)
        );
        stage_databases(&guard, &KEY).unwrap();
        assert_preserved_and_prepared(root.path());
    }
}

fn crash(root: &Path, point: &str) {
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "migration::tests::crash_driver",
            "--ignored",
            "--nocapture",
        ])
        .env("PROTONX_SYNTHETIC_MIGRATION_ROOT", root)
        .env("PROTONX_SYNTHETIC_CRASH_POINT", point)
        .output()
        .unwrap();
    assert_eq!(
        output.status.code(),
        Some(73),
        "Synthetic child did not reach its checkpoint"
    );
}
#[test]
#[ignore = "subprocess-only synthetic interruption driver"]
fn crash_driver() {
    let root = PathBuf::from(std::env::var_os("PROTONX_SYNTHETIC_MIGRATION_ROOT").unwrap());
    let point = std::env::var("PROTONX_SYNTHETIC_CRASH_POINT").unwrap();
    let guard = ProfileGuard::acquire(&root).unwrap();
    stage_with_checkpoints(&guard, &KEY, |checkpoint| {
        let name = match checkpoint {
            Checkpoint::ManifestCreated => "manifest".to_owned(),
            Checkpoint::ExportDurable(i) => format!("export-{i}"),
            Checkpoint::ProgressDurable(i) => format!("progress-{i}"),
            Checkpoint::Prepared => "prepared".to_owned(),
        };
        if point == name {
            std::process::exit(73);
        } // No destructors/cleanup.
    })
    .unwrap();
    panic!("Synthetic checkpoint was not reached");
}
fn snapshot_files(root: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    fn visit(root: &Path, output: &mut Vec<(PathBuf, Vec<u8>)>) {
        for child in fs::read_dir(root).unwrap() {
            let path = child.unwrap().path();
            if path.is_dir() {
                visit(&path, output);
            } else {
                output.push((path.clone(), fs::read(path).unwrap()));
            }
        }
    }
    let mut output = vec![];
    visit(root, &mut output);
    output.sort();
    output
}

#[test]
fn changed_sources_and_added_databases_require_explicit_recovery() {
    for added in [false, true] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), "progress-0");
        if added {
            drop(seed(&root.path().join("users/new/mail.db")));
        } else {
            let db = Connection::open(root.path().join("users/synthetic-user/mail.db")).unwrap();
            db.execute(
                "INSERT INTO drafts(body,state) VALUES('synthetic-new-draft','pending')",
                [],
            )
            .unwrap();
        }
        let before = snapshot_files(root.path());
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert_eq!(
            stage_databases(&guard, &KEY),
            Err(StorageError::SourceChanged)
        );
        assert_eq!(snapshot_files(root.path()), before);
    }
}

#[test]
fn damaged_or_missing_completed_exports_are_retained_and_refused() {
    for missing in [false, true] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), "progress-0");
        let path = stages(root.path())[0].clone();
        if missing {
            fs::remove_file(&path).unwrap();
        } else {
            let mut bytes = fs::read(&path).unwrap();
            bytes[128] ^= 0xff;
            fs::write(&path, bytes).unwrap();
        }
        let before = snapshot_files(root.path());
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert_eq!(
            stage_databases(&guard, &KEY),
            Err(StorageError::RecoveryRequired)
        );
        assert_eq!(snapshot_files(root.path()), before);
    }
}

#[test]
fn malformed_unsupported_and_traversing_manifests_do_not_touch_sources() {
    for change in ["traversal", "version", "duplicate", "oversize", "missing"] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), "manifest");
        let directory = root.path().join(MIGRATION_DIRECTORY);
        let path = directory.join(MANIFEST);
        if change == "missing" {
            fs::remove_file(&path).unwrap();
        } else if change == "oversize" {
            fs::write(&path, vec![b' '; MAX_MANIFEST as usize + 1]).unwrap();
        } else {
            let mut value = load_manifest(&directory).unwrap();
            match change {
                "traversal" => value.databases[0].relative = "sessions/../../outside.db".into(),
                "version" => value.version = 99,
                "duplicate" => value.databases[1].relative = value.databases[0].relative.clone(),
                _ => unreachable!(),
            }
            save_manifest(&directory, &value).unwrap();
        }
        let before = snapshot_files(root.path());
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert!(stage_databases(&guard, &KEY).is_err());
        assert_eq!(snapshot_files(root.path()), before);
    }
}

#[test]
fn symlink_and_hardlink_staging_destinations_are_refused() {
    for hardlink in [false, true] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), "manifest");
        let outside = root.path().join("synthetic-outside");
        fs::write(&outside, b"SYNTHETIC-OUTSIDE-UNCHANGED").unwrap();
        let stage = stages(root.path())[0].clone();
        if hardlink {
            fs::hard_link(&outside, &stage).unwrap();
        } else {
            symlink(&outside, &stage).unwrap();
        }
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert_eq!(
            stage_databases(&guard, &KEY),
            Err(StorageError::InvalidProfile)
        );
        assert_eq!(fs::read(outside).unwrap(), b"SYNTHETIC-OUTSIDE-UNCHANGED");
    }
}

#[test]
fn format_and_migration_markers_gate_helpers_even_without_databases() {
    let root = tempfile::tempdir().unwrap();
    let guard = ProfileGuard::acquire(root.path()).unwrap();
    fs::write(root.path().join(FORMAT_FILE), ENCRYPTED_FORMAT).unwrap();
    assert_eq!(
        guard.check_startup(false),
        Err(StorageError::EncryptedProfile)
    );
    assert!(guard.check_startup(true).is_ok());
    fs::write(root.path().join(FORMAT_FILE), b"unknown-format").unwrap();
    assert_eq!(guard.check_startup(true), Err(StorageError::InvalidProfile));
    fs::create_dir(root.path().join(MIGRATION_DIRECTORY)).unwrap();
    assert_eq!(
        guard.check_startup(false),
        Err(StorageError::MigrationPending)
    );
    assert_eq!(
        guard.check_startup(true),
        Err(StorageError::MigrationPending)
    );
}

#[test]
fn source_uri_escapes_reserved_and_non_ascii_path_bytes_and_remains_read_only() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("users/synthetic ?mode=rw#%é/mail.db");
    drop(seed(&path));
    let before = fs::read(&path).unwrap();
    let guard = ProfileGuard::acquire(root.path()).unwrap();
    stage_databases(&guard, &KEY).unwrap();
    assert_eq!(fs::read(&path).unwrap(), before);
    let staged = stage_path(&root.path().join(MIGRATION_DIRECTORY), 0);
    let db = Connection::open(staged).unwrap();
    key_connection(&db, &KEY).unwrap();
    assert_eq!(
        db.query_row("SELECT body FROM drafts", [], |r| r.get::<_, String>(0))
            .unwrap(),
        MARKER
    );
}

#[test]
fn initial_preparation_refuses_existing_or_unknown_format_without_staging() {
    for format in [ENCRYPTED_FORMAT, b"unknown-format".as_slice()] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        fs::write(root.path().join(FORMAT_FILE), format).unwrap();
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        let before = snapshot_files(root.path());
        assert!(stage_databases(&guard, &KEY).is_err());
        assert_eq!(snapshot_files(root.path()), before);
        assert!(!root.path().join(MIGRATION_DIRECTORY).exists());
    }
}
