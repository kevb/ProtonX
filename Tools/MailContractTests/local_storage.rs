// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Documents the pinned SDK's current storage boundary, not a desired security guarantee.
use mail_common::models::RawMessageBody;
use mail_common::test_utils::db::new_test_connection_file;
use mail_common::test_utils::scroller::{StoreLabeledModelMap, test_messages};
use mail_crypto_inbox::message::RawDecryptedBody;
use mail_sqlite3::rusqlite::Connection;
use mail_stash::orm::Model;
use std::collections::HashMap;

#[tokio::test]
async fn pinned_sdk_mail_database_contains_plaintext_after_body_storage() {
    // Only an isolated temporary database and Proton's public synthetic records.
    // Never point this test at an installed ProtonX profile.
    let (stash, directory) = new_test_connection_file().await;
    let mut tether = stash.connection();
    let mut data = HashMap::from([(vec!["synthetic-inbox"], test_messages(1, 0))]);
    data.save_to_database(&mut tether).await;
    let id = data[&vec!["synthetic-inbox"]][0].id();
    let marker = b"PROTONX-SYNTHETIC-LOCAL-BODY-AUDIT";
    let body = RawMessageBody::ok(RawDecryptedBody::new_plain(marker.to_vec(), vec![]));
    tether
        .write_tx(async |tx| body.store(id, None, tx).await)
        .await
        .unwrap();

    let path = directory.path().join("test");
    // An ordinary SQLite connection with no Keychain key can read decoded bodies.
    let connection = Connection::open(&path).unwrap();
    let stored: Vec<u8> = connection
        .query_row("SELECT body FROM raw_message_body", [], |row| row.get(0))
        .unwrap();
    assert_eq!(stored, marker);
    assert!(
        std::fs::read(path)
            .unwrap()
            .starts_with(b"SQLite format 3\0")
    );
    // A secure-cache milestone must replace this baseline with wrong/missing-key
    // rejection tests and plaintext absence checks for the database and journals.
}
