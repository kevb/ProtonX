// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
use protonx_mail_storage::{MAX_BLOB, read_blob, write_blob};
use std::fs;
use std::os::unix::fs::{PermissionsExt, symlink};
const KEY: [u8; 32] = [0x35; 32];
const BODY: &[u8] = b"PROTONX-SYNTHETIC-ATTACHMENT-AND-EMBEDDED-MIME";

#[test]
fn attachment_roundtrip_is_atomic_private_and_never_plaintext() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("content.pxb");
    write_blob(&path, BODY, &KEY).unwrap();
    assert_eq!(read_blob(&path, &KEY).unwrap(), BODY);
    assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert!(read_blob(&path, &[0x99; 32]).is_err());
    let original = fs::read(&path).unwrap();
    assert!(!original.starts_with(b"SQLite format 3\0"));
    assert!(!original.windows(BODY.len()).any(|b| b == BODY));
    assert!(write_blob(&path, &vec![0; MAX_BLOB + 1], &KEY).is_err());
    assert_eq!(fs::read(&path).unwrap(), original);
    write_blob(&path, b"synthetic replacement", &KEY).unwrap();
    assert_eq!(read_blob(&path, &KEY).unwrap(), b"synthetic replacement");
    write_blob(&path, b"", &KEY).unwrap();
    assert!(read_blob(&path, &KEY).unwrap().is_empty());
    assert_eq!(fs::read_dir(directory.path()).unwrap().count(), 1);
}

#[test]
fn plaintext_corruption_symlinks_and_hardlinks_fail_without_resetting() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("content.pxb");
    fs::write(&path, BODY).unwrap();
    assert!(read_blob(&path, &KEY).is_err());
    assert_eq!(fs::read(&path).unwrap(), BODY);
    fs::remove_file(&path).unwrap();
    write_blob(&path, BODY, &KEY).unwrap();
    let bytes = fs::read(&path).unwrap();
    let link = directory.path().join("link");
    symlink(&path, &link).unwrap();
    assert!(read_blob(&link, &KEY).is_err());
    assert!(write_blob(&link, BODY, &KEY).is_err());
    fs::remove_file(&link).unwrap();
    fs::hard_link(&path, &link).unwrap();
    assert!(read_blob(&path, &KEY).is_err());
    assert!(write_blob(&path, BODY, &KEY).is_err());
    fs::remove_file(&link).unwrap();
    let mut broken = bytes.clone();
    broken[500] ^= 0xff;
    fs::write(&path, &broken).unwrap();
    assert!(read_blob(&path, &KEY).is_err());
    assert_eq!(fs::read(&path).unwrap(), broken);
}
