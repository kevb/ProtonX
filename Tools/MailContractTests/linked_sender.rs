// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Uses Proton's public synthetic fixture construction from draft_change_sender.rs.
mod drafts_common;
use drafts_common::draft_test_params;
use mail_api::services::proton::common::{ConversationId, MessageId};
use mail_api::services::proton::prelude::MimeType;
use mail_common::datatypes::{MessageFlags, ParsedHeaders};
use mail_common::draft::{Draft, ReplyMode};
use mail_common::models::{Message, MessageBodyMetadata, RawMessageBody};
use mail_common::test_utils::message_body::{TEST_USER_ID, message_body_test_user_secret};
use mail_common::test_utils::test_context::MailTestContext;
use mail_core_api::services::proton::UserId;
use mail_core_common::datatypes::AddressFlags;
use mail_core_common::models::{Address, ModelIdExtension};
use mail_stash::orm::Model;
use std::collections::HashMap;

#[tokio::test]
async fn linked_gmail_reply_preserves_sender_and_byoe_policy() {
    let ctx = MailTestContext::with_user_secret_and_user_id(
        message_body_test_user_secret(),
        UserId::from(TEST_USER_ID),
    )
    .await;
    let params = draft_test_params();
    ctx.setup_user(params.clone()).await;
    let user_ctx = ctx.mail_user_context().await;
    let mut tether = user_ctx.user_stash().connection();
    let mut old_address = Address::find_by_remote_id(params.addresses[0].id.clone(), &tether)
        .await
        .unwrap()
        .unwrap();
    old_address.email = "alex.demo@gmail.com".into();
    old_address.flags = Some(AddressFlags::BYOE);
    tether
        .write_tx(async |tx| old_address.save(tx).await)
        .await
        .unwrap();
    let mut message = Message {
        local_id: None,
        remote_id: Some(MessageId::from("MESSAGE")),
        local_conversation_id: None,
        remote_conversation_id: Some(ConversationId::from("CONV")),
        local_address_id: old_address.id(),
        remote_address_id: old_address.remote_id.clone().unwrap(),
        attachments_metadata: vec![],
        cc_list: Default::default(),
        bcc_list: Default::default(),
        deleted: false,
        location: None,
        expiration_time: Default::default(),
        external_id: None,
        flags: MessageFlags::RECEIVED,
        is_forwarded: false,
        is_replied: false,
        is_replied_all: false,
        label_ids: vec![],
        num_attachments: 0,
        display_order: 0,
        sender: Default::default(),
        size: 0,
        snooze_time: Default::default(),
        subject: "".to_string(),
        time: Default::default(),
        to_list: Default::default(),
        unread: false,
        custom_labels: vec![],
    };
    let mut message_body_metadata = MessageBodyMetadata {
        local_message_id: None,
        remote_message_id: message.remote_id.clone(),
        header: "".to_string(),
        mime_type: MimeType::TextHtml.into(),
        parsed_headers: ParsedHeaders {
            headers: HashMap::from([(
                "X-Original-To".to_owned(),
                serde_json::Value::String("alex.demo@gmail.com".to_owned()),
            )]),
        },
        attachments: vec![],
        reply_to: Default::default(),
        reply_tos: vec![],
    };

    tether
        .write_tx(async |tx| {
            message.save(tx).await.unwrap();
            message_body_metadata.save(tx).await.unwrap();

            RawMessageBody::local_draft("Hello world")
                .store(message.id(), None, tx)
                .await
        })
        .await
        .unwrap();

    for mode in [ReplyMode::Sender, ReplyMode::All] {
        let draft = Draft::reply(&user_ctx, message.id(), mode, true)
            .await
            .unwrap();
        let state = draft.state().await.unwrap();
        assert_eq!(state.sender, "alex.demo@gmail.com");
        assert!(
            Address::find_by_remote_id(state.address_id, &tether)
                .await
                .unwrap()
                .unwrap()
                .is_byoe()
        );
        assert!(
            draft
                .sender_addresses()
                .await
                .unwrap()
                .iter()
                .any(|a| a.email == "alex.demo@gmail.com")
        );
    }
    // Ordinary forwarding does not manufacture a send-as-Gmail identity.
    let senders = Address::all_send_enabled(&tether).await.unwrap();
    assert!(!senders.iter().any(|a| a.email == "unconnected@gmail.com"));
}
