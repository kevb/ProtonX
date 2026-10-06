// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
use mail_common::models::RawMessageBody;
use mail_common::test_utils::db::new_test_connection_file;
use mail_common::test_utils::scroller::{StoreLabeledModelMap, test_messages};
use mail_crypto_inbox::message::RawDecryptedBody;
use mail_stash::orm::Model;
use protonx_mail_storage::{configure_database_key, key_connection, validate_encrypted};
use rusqlite::Connection;
use std::collections::HashMap;

#[tokio::test]
async fn sdk_pool_reads_local_body_from_encrypted_database_without_a_server() {
    const KEY: [u8; 32] = [0x42; 32];
    configure_database_key(KEY).unwrap();
    assert!(configure_database_key([0x99; 32]).is_err());
    let (stash, directory) = new_test_connection_file().await;
    let mut tether = stash.connection();
    let mut data = HashMap::from([(vec!["synthetic-inbox"], test_messages(1, 0))]);
    data.save_to_database(&mut tether).await;
    let id = data[&vec!["synthetic-inbox"]][0].id();
    let marker = b"PROTONX-SYNTHETIC-SDK-ENCRYPTED-BODY";
    let body = RawMessageBody::ok(RawDecryptedBody::new_plain(marker.to_vec(), vec![]));
    tether
        .write_tx(async |tx| body.store(id, None, tx).await)
        .await
        .unwrap();
    let stored = RawMessageBody::load(id, &tether).await.unwrap().unwrap();
    assert_eq!(stored.body(), marker);
    let path = directory.path().join("test");
    validate_encrypted(&path, &KEY).unwrap();
    let plain = Connection::open(&path).unwrap();
    assert!(
        plain
            .query_row("SELECT body FROM raw_message_body", [], |r| r
                .get::<_, Vec<u8>>(0))
            .is_err()
    );
    let reopened = Connection::open(&path).unwrap();
    key_connection(&reopened, &KEY).unwrap();
    assert_eq!(
        reopened
            .query_row("SELECT body FROM raw_message_body", [], |r| r
                .get::<_, Vec<u8>>(0))
            .unwrap(),
        marker
    );
    for file in std::fs::read_dir(directory.path()).unwrap() {
        let path = file.unwrap().path();
        if path.is_file() {
            let data = std::fs::read(path).unwrap();
            assert!(!data.windows(marker.len()).any(|b| b == marker));
        }
    }
}
