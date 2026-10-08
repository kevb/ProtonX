// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// SDK-native cache bytes, including binary and empty files, never returned as a cache path.
use mail_common::{DecryptedAttachment, models::Attachment};
use mail_common::test_utils::{init::Params, test_context::MailTestContext};
use mail_stash::orm::Model;

#[tokio::test]
async fn native_export_reads_sdk_owned_cache_and_refuses_oversized_metadata() {
    #[cfg(feature = "protonx-encrypted")]
    protonx_mail_storage::configure_database_key([0x74; 32]).unwrap();
    let context = MailTestContext::new().await;
    context.setup_user(Params::default_basic()).await;
    let user = context.mail_user_context().await;
    let mut tether = user.user_stash().connection();
    for data in [b"SYNTHETIC\0\xff\xfe".as_slice(), b"".as_slice()] {
        let mut attachment = Attachment { filename: "fixture.bin".into(), size: data.len() as u64, ..Default::default() };
        let path = tether.write_tx(async |tx| {
            attachment.save(tx).await?;
            Attachment::store_in_cache(&user, &attachment.filename, attachment.id(), data.to_vec(), tx).await
        }).await.unwrap();
        let mut decrypted = DecryptedAttachment { attachment_metadata: mail_common::datatypes::AttachmentMetadata {
            local_id: Some(attachment.id()), attachment_type: attachment.attachment_type, disposition: attachment.disposition,
            mime_type: attachment.mime_type, filename: attachment.filename, size: data.len() as u64,
        }, data_path: path };
        assert_eq!(decrypted.native_content().await.unwrap(), data);
        #[cfg(feature = "protonx-encrypted")]
        {
            assert_eq!(decrypted.data_path.file_name().unwrap(), "content.pxb");
            if !data.is_empty() { assert!(!std::fs::read(&decrypted.data_path).unwrap().windows(data.len()).any(|b| b == data)); }
        }
        decrypted.attachment_metadata.size = 25_000_001;
        assert!(decrypted.native_content().await.is_err());
    }
}
