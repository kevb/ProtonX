// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Real SDK schema/local models, synthetic opaque queue rows. No queue execution,
// network, authentication or claim of real pending-message delivery safety.
use mail_common::models::{Attachment, RawMessageBody, attachment_cache::AttachmentCacheMetadata};
use mail_common::test_utils::db::new_test_connection_file;
use mail_common::test_utils::scroller::{StoreLabeledModelMap, test_messages};
use mail_crypto_inbox::message::RawDecryptedBody;
use mail_stash::orm::Model;
use protonx_mail_storage::{
    ProfileGuard, key_connection, migration::stage_attachment_cache, read_blob,
};
use rusqlite::Connection;
use std::{collections::HashMap, fs};

#[tokio::test]
async fn sdk_schema_body_draft_and_queue_bytes_survive_staging_without_execution() {
    const KEY: [u8; 32] = [0x71; 32];
    const CACHE: &[u8] = b"SYNTHETIC-MIGRATED-SDK-ATTACHMENT";
    let root = tempfile::tempdir().unwrap();
    let cache_path = root
        .path()
        .join("cache/attachments/synthetic/1/private-fixture.txt");
    fs::create_dir_all(cache_path.parent().unwrap()).unwrap();
    fs::write(&cache_path, CACHE).unwrap();
    let (stash, source_directory) = new_test_connection_file().await;
    let mut tether = stash.connection();
    let mut data = HashMap::from([(vec!["synthetic-inbox"], test_messages(1, 0))]);
    data.save_to_database(&mut tether).await;
    let id = data[&vec!["synthetic-inbox"]][0].id();
    let marker = b"PROTONX-SYNTHETIC-MIGRATED-SDK-BODY";
    let body = RawMessageBody::ok(RawDecryptedBody::new_plain(marker.to_vec(), vec![]));
    tether
        .write_tx(async |tx| body.store(id, None, tx).await)
        .await
        .unwrap();
    let mut attachment = Attachment {
        filename: "private-fixture.txt".into(),
        ..Default::default()
    };
    tether
        .write_tx(async |tx| {
            attachment.save(tx).await?;
            AttachmentCacheMetadata {
                attachment_id: attachment.id(),
                atime: 1,
                ctime: 1,
                hit_count: 0,
                path: cache_path.to_str().unwrap().to_owned(),
                size: CACHE.len() as u64,
            }
            .save(tx)
            .await
        })
        .await
        .unwrap();
    drop(tether);
    drop(stash); // Feature joins the SDK's worker connections before moving file.

    let path = root.path().join("users/synthetic/mail.db");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::rename(source_directory.path().join("test"), &path).unwrap();
    let source = Connection::open(&path).unwrap();
    // Preserve opaque bytes in the pinned SDK's actual action_queue table. This
    // row is intentionally a fixture type and cannot be dispatched as a send.
    source.execute("INSERT INTO action_queue(id,action_type,version,priority,state,action_group) VALUES(901,'protonx-synthetic-fixture',1,0,?1,'synthetic')", [b"SYNTHETIC-PENDING-QUEUE-BYTES".as_slice()]).unwrap();
    source.execute("INSERT INTO draft_metadata(local_message_id,send_action_id) SELECT local_id,901 FROM messages LIMIT 1", []).unwrap();
    let before_queue: Vec<u8> = source
        .query_row("SELECT state FROM action_queue WHERE id=901", [], |r| {
            r.get(0)
        })
        .unwrap();
    let before_draft: (i64, i64) = source
        .query_row(
            "SELECT local_message_id,send_action_id FROM draft_metadata",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .unwrap();
    let before_schema: Vec<(String, String)> = source
        .prepare("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    drop(source);
    let source_bytes = fs::read(&path).unwrap();

    let guard = ProfileGuard::acquire(root.path()).unwrap();
    assert_eq!(stage_attachment_cache(&guard, &KEY).unwrap().files, 1);
    assert_eq!(fs::read(&path).unwrap(), source_bytes);
    assert_eq!(fs::read(&cache_path).unwrap(), CACHE);
    assert_eq!(
        read_blob(
            &root
                .path()
                .join(".storage-migration/attachment-stage/asset-0000.pxb"),
            &KEY
        )
        .unwrap(),
        CACHE
    );
    let staged = root.path().join(".storage-migration/stage-000.db");
    let encrypted = Connection::open(&staged).unwrap();
    key_connection(&encrypted, &KEY).unwrap();
    // Staging preserves SDK references. Updating these absolute paths belongs to
    // a separately tested cutover; never point the retained original at a stage.
    assert_eq!(
        encrypted
            .query_row("SELECT path,size FROM attachment_cache", [], |r| Ok((
                r.get::<_, String>(0)?,
                r.get::<_, u64>(1)?
            )))
            .unwrap(),
        (cache_path.to_str().unwrap().to_owned(), CACHE.len() as u64)
    );
    assert_eq!(
        encrypted
            .query_row("SELECT body FROM raw_message_body", [], |r| r
                .get::<_, Vec<u8>>(0))
            .unwrap(),
        marker
    );
    assert_eq!(
        encrypted
            .query_row("SELECT state FROM action_queue WHERE id=901", [], |r| r
                .get::<_, Vec<u8>>(0))
            .unwrap(),
        before_queue
    );
    assert_eq!(
        encrypted
            .query_row(
                "SELECT local_message_id,send_action_id FROM draft_metadata",
                [],
                |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?))
            )
            .unwrap(),
        before_draft
    );
    let after_schema: Vec<(String, String)> = encrypted
        .prepare("SELECT name,sql FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(after_schema, before_schema);
    drop(encrypted);
    let bytes = fs::read(staged).unwrap();
    assert!(!bytes.windows(marker.len()).any(|b| b == marker));
}
