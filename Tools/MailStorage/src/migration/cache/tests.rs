// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
use super::*;
use crate::migration::stage_databases;
use rusqlite::Connection;
use std::os::unix::fs::symlink;
use std::process::Command;

const KEY: [u8; 32] = [0x47; 32];
const NAME: &str = "synthetic-confidential-filename.pdf";
const BODY: &[u8] = b"SYNTHETIC-ATTACHMENT-PRIVATE-CONTENT";
fn fixture(root: &Path) {
    fs::create_dir_all(root.join("sessions")).unwrap();
    let db = Connection::open(root.join("sessions/account.db")).unwrap();
    db.execute_batch(
        "CREATE TABLE pending(id INTEGER, state TEXT); INSERT INTO pending VALUES(1,'uncertain');",
    )
    .unwrap();
    fs::create_dir_all(root.join("cache/attachments/account/message")).unwrap();
    fs::write(
        root.join("cache/attachments/account/message").join(NAME),
        BODY,
    )
    .unwrap();
    fs::write(
        root.join("cache/attachments/account/message/empty.mime"),
        [],
    )
    .unwrap();
}
fn directory(root: &Path) -> PathBuf {
    root.join(MIGRATION_DIRECTORY).join(DIRECTORY)
}
fn load(root: &Path) -> Plan {
    serde_json::from_slice(&read_blob(&directory(root).join(PLAN), &KEY).unwrap()).unwrap()
}
fn assert_prepared(root: &Path) {
    let plan = load(root);
    assert!(plan.prepared);
    assert_eq!(plan.files.len(), 2);
    for (index, entry) in plan.files.iter().enumerate() {
        assert_eq!(
            read_blob(&asset_path(&directory(root), index), &KEY).unwrap(),
            fs::read(root.join(&entry.relative)).unwrap()
        );
    }
    for child in fs::read_dir(directory(root)).unwrap() {
        let path = child.unwrap().path();
        let data = fs::read(&path).unwrap();
        for marker in [
            NAME.as_bytes(),
            BODY,
            b"cache/attachments/account/message".as_slice(),
        ] {
            assert!(!data.windows(marker.len()).any(|s| s == marker));
        }
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert_eq!(
        fs::metadata(directory(root)).unwrap().permissions().mode() & 0o777,
        0o700
    );
}

#[test]
fn stages_empty_and_nonempty_payloads_with_encrypted_paths_without_mutating_originals() {
    let root = tempfile::tempdir().unwrap();
    fixture(root.path());
    let db_path = root.path().join("sessions/account.db");
    let db_before = fs::read(&db_path).unwrap();
    let guard = ProfileGuard::acquire(root.path()).unwrap();
    assert_eq!(
        stage_attachment_cache(&guard, &KEY).unwrap(),
        AttachmentMigrationSummary {
            files: 2,
            prepared: true
        }
    );
    assert_prepared(root.path());
    assert_eq!(fs::read(db_path).unwrap(), db_before);
    assert_eq!(
        guard.check_startup(false),
        Err(StorageError::MigrationPending)
    );
    assert_eq!(
        guard.check_startup(true),
        Err(StorageError::MigrationPending)
    );
    let plan_before = fs::read(directory(root.path()).join(PLAN)).unwrap();
    let asset_before = fs::read(asset_path(&directory(root.path()), 1)).unwrap();
    stage_attachment_cache(&guard, &KEY).unwrap();
    stage_databases(&guard, &KEY).unwrap(); // Database-only resume recognizes protected cache stage.
    assert_eq!(
        fs::read(directory(root.path()).join(PLAN)).unwrap(),
        plan_before
    );
    assert_eq!(
        fs::read(asset_path(&directory(root.path()), 1)).unwrap(),
        asset_before
    );
}

#[test]
fn absent_cache_is_an_explicit_empty_encrypted_plan() {
    let root = tempfile::tempdir().unwrap();
    fixture(root.path());
    fs::remove_dir_all(root.path().join("cache")).unwrap();
    let guard = ProfileGuard::acquire(root.path()).unwrap();
    assert_eq!(stage_attachment_cache(&guard, &KEY).unwrap().files, 0);
    assert!(load(root.path()).prepared);
    stage_attachment_cache(&guard, &KEY).unwrap();
    fs::create_dir_all(root.path().join("cache/attachments")).unwrap();
    fs::write(root.path().join("cache/attachments/new"), BODY).unwrap();
    assert_eq!(
        stage_attachment_cache(&guard, &KEY),
        Err(StorageError::SourceChanged)
    );
}

fn crash(root: &Path, point: &str) {
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "migration::cache::tests::crash_driver",
            "--ignored",
        ])
        .env("PROTONX_SYNTHETIC_CACHE_ROOT", root)
        .env("PROTONX_SYNTHETIC_CACHE_STOP", point)
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(74));
}
#[test]
#[ignore = "subprocess-only synthetic interruption driver"]
fn crash_driver() {
    let root = PathBuf::from(std::env::var_os("PROTONX_SYNTHETIC_CACHE_ROOT").unwrap());
    let stop = std::env::var("PROTONX_SYNTHETIC_CACHE_STOP").unwrap();
    let guard = ProfileGuard::acquire(&root).unwrap();
    stage_with_checkpoints(&guard, &KEY, |point| {
        let label = match point {
            Checkpoint::Plan => "plan".to_owned(),
            Checkpoint::Export(i) => format!("export-{i}"),
            Checkpoint::Progress(i) => format!("progress-{i}"),
            Checkpoint::Prepared => "prepared".to_owned(),
        };
        if label == stop {
            std::process::exit(74);
        }
    })
    .unwrap();
    panic!("Synthetic checkpoint not reached");
}
#[test]
fn process_death_resumes_at_all_six_durable_attachment_transitions() {
    for point in [
        "plan",
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
        assert_eq!(
            guard.check_startup(true),
            Err(StorageError::MigrationPending)
        );
        stage_attachment_cache(&guard, &KEY).unwrap();
        assert_prepared(root.path());
    }
}
#[test]
fn wrong_key_stops_before_any_cache_modification() {
    for point in ["plan", "export-0", "prepared"] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), point);
        let before = fs::read(directory(root.path()).join(PLAN)).unwrap();
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert_eq!(
            stage_attachment_cache(&guard, &[0x99; 32]),
            Err(StorageError::RecoveryRequired)
        );
        assert_eq!(fs::read(directory(root.path()).join(PLAN)).unwrap(), before);
        stage_attachment_cache(&guard, &KEY).unwrap();
    }
}
#[test]
fn changed_added_removed_cache_and_changed_database_stop_resume() {
    for change in 0..4 {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), "plan");
        let original = root
            .path()
            .join("cache/attachments/account/message")
            .join(NAME);
        match change {
            0 => fs::write(&original, b"different synthetic bytes").unwrap(),
            1 => fs::write(root.path().join("cache/attachments/new"), BODY).unwrap(),
            2 => fs::remove_file(&original).unwrap(),
            _ => {
                Connection::open(root.path().join("sessions/account.db"))
                    .unwrap()
                    .execute("UPDATE pending SET state='changed'", [])
                    .unwrap();
            }
        }
        let before = fs::read(directory(root.path()).join(PLAN)).unwrap();
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert_eq!(
            stage_attachment_cache(&guard, &KEY),
            Err(StorageError::SourceChanged)
        );
        assert_eq!(fs::read(directory(root.path()).join(PLAN)).unwrap(), before);
        assert!(!asset_path(&directory(root.path()), 0).exists());
    }
}
#[test]
fn damaged_missing_or_plaintext_stages_are_retained_and_never_regenerated() {
    for acknowledged in [false, true] {
        for damage in 0..3 {
            let root = tempfile::tempdir().unwrap();
            fixture(root.path());
            crash(
                root.path(),
                if acknowledged {
                    "progress-0"
                } else {
                    "export-0"
                },
            );
            let path = asset_path(&directory(root.path()), 0);
            match damage {
                0 => {
                    let mut bytes = fs::read(&path).unwrap();
                    bytes[200] ^= 1;
                    fs::write(&path, bytes).unwrap();
                }
                1 => fs::remove_file(&path).unwrap(),
                _ => fs::write(&path, b"unknown plaintext").unwrap(),
            }
            let guard = ProfileGuard::acquire(root.path()).unwrap();
            if !acknowledged && damage == 1 {
                // No acknowledged output existed; recreating this reserved slot is safe.
                stage_attachment_cache(&guard, &KEY).unwrap();
                continue;
            }
            let before = fs::read(&path).ok();
            assert!(stage_attachment_cache(&guard, &KEY).is_err());
            assert_eq!(fs::read(&path).ok(), before);
        }
    }
}
#[test]
fn source_links_and_oversize_files_fail_before_cache_plan_creation() {
    for variant in 0..4 {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        let path = root
            .path()
            .join("cache/attachments/account/message")
            .join(NAME);
        match variant {
            0 => {
                fs::remove_file(&path).unwrap();
                symlink("empty.mime", &path).unwrap();
            }
            1 => fs::hard_link(&path, root.path().join("linked")).unwrap(),
            2 => {
                OpenOptions::new()
                    .write(true)
                    .open(&path)
                    .unwrap()
                    .set_len(MAX_BLOB as u64 + 1)
                    .unwrap();
            }
            _ => {
                fs::rename(
                    root.path().join("cache/attachments"),
                    root.path().join("outside"),
                )
                .unwrap();
                symlink(
                    root.path().join("outside"),
                    root.path().join("cache/attachments"),
                )
                .unwrap();
            }
        }
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert_eq!(
            stage_attachment_cache(&guard, &KEY),
            Err(StorageError::InvalidProfile)
        );
        assert!(!directory(root.path()).exists());
    }
}
#[test]
fn hostile_stage_paths_and_permissions_stop_both_staging_entrypoints() {
    for variant in 0..4 {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), "plan");
        let target = directory(root.path());
        match variant {
            0 => {
                fs::rename(&target, root.path().join("outside")).unwrap();
                symlink(root.path().join("outside"), &target).unwrap();
            }
            1 => symlink(
                root.path().join("sessions/account.db"),
                target.join("asset-0000.pxb"),
            )
            .unwrap(),
            2 => fs::hard_link(target.join(PLAN), target.join("asset-0000.pxb")).unwrap(),
            _ => fs::set_permissions(target.join(PLAN), fs::Permissions::from_mode(0o644)).unwrap(),
        }
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert_eq!(
            stage_attachment_cache(&guard, &KEY),
            Err(StorageError::InvalidProfile)
        );
        assert_eq!(
            stage_databases(&guard, &KEY),
            Err(StorageError::InvalidProfile)
        );
    }
}
#[test]
fn missing_damaged_unknown_version_and_traversing_plans_fail_closed() {
    for variant in 0..4 {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        crash(root.path(), "plan");
        let path = directory(root.path()).join(PLAN);
        match variant {
            0 => fs::remove_file(&path).unwrap(),
            1 => fs::write(&path, b"broken synthetic plan").unwrap(),
            _ => {
                let mut plan = load(root.path());
                if variant == 2 {
                    plan.version = 99;
                } else {
                    plan.files[0].relative = "cache/attachments/../../outside".into();
                }
                save_plan(&directory(root.path()), &plan, &KEY).unwrap();
            }
        }
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        assert!(stage_attachment_cache(&guard, &KEY).is_err());
        assert!(!asset_path(&directory(root.path()), 0).exists());
        assert_eq!(
            guard.check_startup(true),
            Err(StorageError::MigrationPending)
        );
    }
}

#[test]
fn unplanned_reserved_output_is_retained_and_refused() {
    let root = tempfile::tempdir().unwrap();
    fixture(root.path());
    crash(root.path(), "plan");
    let unexpected = asset_path(&directory(root.path()), 27);
    write_blob(&unexpected, BODY, &KEY).unwrap();
    let before = fs::read(&unexpected).unwrap();
    let guard = ProfileGuard::acquire(root.path()).unwrap();
    assert_eq!(
        stage_attachment_cache(&guard, &KEY),
        Err(StorageError::InvalidProfile)
    );
    assert_eq!(fs::read(unexpected).unwrap(), before);
}

#[test]
fn source_change_during_export_or_preparation_is_detected() {
    for database in [false, true] {
        let root = tempfile::tempdir().unwrap();
        fixture(root.path());
        let guard = ProfileGuard::acquire(root.path()).unwrap();
        let result = stage_with_checkpoints(&guard, &KEY, |point| {
            if matches!(point, Checkpoint::Export(1)) {
                if database {
                    Connection::open(root.path().join("sessions/account.db"))
                        .unwrap()
                        .execute("UPDATE pending SET state='changed'", [])
                        .unwrap();
                } else {
                    fs::write(
                        root.path()
                            .join("cache/attachments/account/message")
                            .join(NAME),
                        b"changed synthetic payload",
                    )
                    .unwrap();
                }
            }
        });
        assert_eq!(result, Err(StorageError::SourceChanged));
        assert!(!load(root.path()).prepared);
        assert!(root.path().join("sessions/account.db").exists());
    }
}
