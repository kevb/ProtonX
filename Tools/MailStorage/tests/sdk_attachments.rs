// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Genuine pinned SDK cache methods; synthetic account fixture / local mock only.
use mail_common::models::Attachment;
use mail_common::test_utils::{init::Params, test_context::MailTestContext};
use mail_stash::orm::Model;
use protonx_mail_storage::{configure_database_key, read_blob};

#[tokio::test]
async fn sdk_stores_reads_and_clones_attachments_without_plaintext_files() {
    const KEY: [u8; 32] = [0x74; 32];
    const DATA: &[u8] = b"PROTONX-SYNTHETIC-SDK-CACHED-MIME";
    configure_database_key(KEY).unwrap();
    let context = MailTestContext::new().await;
    context.setup_user(Params::default_basic()).await;
    let user = context.mail_user_context().await;
    let mut tether = user.user_stash().connection();
    let mut attachment = Attachment { filename: "private-fixture-name.txt".into(), ..Default::default() };
    let first = tether.write_tx(async |tx| {
        attachment.save(tx).await?;
        Attachment::store_in_cache(&user, &attachment.filename, attachment.id(), DATA.to_vec(), tx).await
    }).await.unwrap();
    assert_eq!(first.file_name().unwrap(), "content.pxb");
    assert_eq!(read_blob(&first, &KEY).unwrap(), DATA);
    // Calls the cache hit path: no remote attachment id or server download exists.
    assert_eq!(attachment.content_data(&user, &mut tether).await.unwrap(), DATA);
    let mut second = Attachment { filename: "another-private-name.txt".into(), ..Default::default() };
    let copied = tether.write_tx(async |tx| {
        second.save(tx).await?;
        Attachment::copy_attachment_to_cache(&user, &second.filename, second.id(), &first, tx).await
    }).await.unwrap();
    assert_ne!(first, copied);
    assert_eq!(read_blob(&copied, &KEY).unwrap(), DATA);
    assert_eq!(second.content_data(&user, &mut tether).await.unwrap(), DATA);
    for path in [first, copied] {
        let bytes = std::fs::read(&path).unwrap();
        assert!(!bytes.windows(DATA.len()).any(|b| b == DATA));
        assert!(!bytes.starts_with(b"SQLite format 3\0"));
    }
}
