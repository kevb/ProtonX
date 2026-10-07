// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Fixture adapted from pinned Proton Mail SDK tests/message_move.rs (AGPL-3.0-only).
// See LICENSE-MAIL-HELPER and upstream.lock.json; all data and HTTP endpoints are synthetic.
use mail_api::services::proton::common::MessageId;
use mail_api::services::proton::response_data::{Conversation as ApiConversation, ConversationCount as ApiConversationCount, MessageCount as ApiMessageCount};
use mail_common::datatypes::SystemLabelId;
use mail_common::models::{Conversation, Message};
use mail_common::test_utils::conversations::ApiConversationTestUtils;
use mail_common::test_utils::init::Params as TestParams;
use mail_common::test_utils::test_context::{MailTestContext, MailUserContextTestExtension};
use mail_common::Mailbox;
use mail_core_api::services::proton::{Address as ApiAddress, LabelId};
use wiremock::matchers::{body_json, method, path};
use wiremock::{Mock, ResponseTemplate};
use mail_core_common::datatypes::AddressFlags;
use mail_core_common::models::{Address, Label, ModelExtension as _, ModelIdExtension as _};
use mail_core_common::test_utils::addresses::ApiAddressTestUtils;
use mail_stash::orm::Model;

#[tokio::test]
async fn linked_gmail_conversation_spam_inbox_and_undo() { linked_gmail_move_and_undo(LabelId::spam()).await; }
#[tokio::test]
async fn linked_gmail_conversation_archive_and_undo() { linked_gmail_move_and_undo(LabelId::archive()).await; }

async fn linked_gmail_move_and_undo(destination: LabelId) {
    let ctx = MailTestContext::new().await;

    let conversation = ApiConversation::test_conversation_in_inbox("first", vec![]);
    let message_id = MessageId::from("message");

    let conversation_count = vec![ApiConversationCount {
        label_id: LabelId::inbox().clone(),
        total: 1,
        unread: 0,
    }];
    let message_count = vec![ApiMessageCount {
        label_id: LabelId::inbox().clone(),
        total: 1,
        unread: 0,
    }];
    let params = TestParams {
        addresses: vec![ApiAddress::test_address()],
        conversations: vec![conversation.clone()],
        conversation_count,
        message_count,
        ..Default::default()
    };
    ctx.setup_user(params).await;

    ctx.mock_label_messages(&LabelId::inbox(), vec![message_id.clone()])
        .await;
    ctx.mock_unlabel_messages(&destination.clone(), vec![message_id.clone()], vec![])
        .await;
    // Spam is queued twice below; assert the exact closed Proton request each time.
    Mock::given(method("PUT"))
        .and(path("/api/mail/v4/conversations/label"))
        .and(body_json(serde_json::json!({
            "Action": 1, "IDs": ["first"], "LabelID": destination,
            "SpamAction": null
        })))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "Code": 1000, "Responses": [{"ID": "first", "Response": {"Code": 1000}}]
        })))
        .expect(if destination == LabelId::spam() { 2 } else { 1 })
        .mount(ctx.mock_server()).await;

    ctx.mock_get_conversations(vec![conversation], 1).await;

    let user_ctx = ctx.mail_user_context().await;
    let mut tether = user_ctx.user_stash().connection();

    // Create a mailbox and sync.
    let mailbox = Mailbox::with_remote_id(&user_ctx.user_stash().connection(), LabelId::inbox())
        .await
        .unwrap();
    mailbox
        .sync(
            &mut user_ctx.user_stash().connection(),
            user_ctx.session(),
            10,
        )
        .await
        .unwrap();

    let local_destination = Label::resolve_local_label_id(destination.clone(), &tether)
        .await
        .unwrap();

    let mut conv = Conversation::load(1.into(), &tether)
        .await
        .unwrap()
        .unwrap();

    // BYOE/Gmail is a Proton receiving identity, not a separate move protocol.
    let mut address = Address::find_by_remote_id(ApiAddress::test_address().id, &tether).await.unwrap().unwrap();
    address.email = "alex.demo@gmail.com".into();
    address.flags = Some(AddressFlags::BYOE);
    tether.write_tx(async |tx| address.save(tx).await).await.unwrap();

    tether
        .write_tx(async |tx| {
            let addr_id = ApiAddress::test_address().id;
            let local_addr_id = Address::remote_id_counterpart(addr_id.clone(), tx)
                .await?
                .unwrap();
            Message {
                local_id: None,
                remote_id: Some(message_id.clone()),
                local_conversation_id: conv.local_id,
                remote_conversation_id: conv.remote_id.clone(),
                label_ids: vec![LabelId::inbox()],
                local_address_id: local_addr_id,
                remote_address_id: addr_id,
                ..Message::test_default()
            }
            .save(tx)
            .await
        })
        .await
        .unwrap();

    conv_is_labeled(&conv, [LabelId::inbox()]);

    // Action:
    // * move the conversation to the SDK destination
    let undo = Conversation::action_move(
        &tether,
        user_ctx.action_queue(),
        local_destination,
        vec![conv.id()],
    )
    .await
    .unwrap()
    .unwrap();

    conv.reload(&tether).await.unwrap();
    conv_is_labeled(&conv, [destination.clone()]);

    undo.undo(user_ctx.action_queue(), &mut tether)
        .await
        .unwrap();
    conv.reload(&tether).await.unwrap();
    conv_is_labeled(&conv, [LabelId::inbox()]);

    let undo = Conversation::action_move(
        &tether,
        user_ctx.action_queue(),
        local_destination,
        vec![conv.id()],
    )
    .await
    .unwrap()
    .unwrap();
    user_ctx.execute_all_actions().await.unwrap();

    conv.reload(&tether).await.unwrap();
    conv_is_labeled(&conv, [destination.clone()]);

    undo.undo(user_ctx.action_queue(), &mut tether)
        .await
        .unwrap();
    user_ctx.execute_all_actions().await.unwrap();
    conv.reload(&tether).await.unwrap();
    conv_is_labeled(&conv, [LabelId::inbox()]);
    if destination == LabelId::spam() {
        ctx.mock_label_conversation(&LabelId::inbox(), vec![conv.remote_id.clone().unwrap()], None, vec![]).await;
        let local_inbox = Label::resolve_local_label_id(LabelId::inbox(), &tether).await.unwrap();
        Conversation::action_move(&tether, user_ctx.action_queue(), local_destination, vec![conv.id()]).await.unwrap();
        user_ctx.execute_all_actions().await.unwrap();
        Conversation::action_move(&tether, user_ctx.action_queue(), local_inbox, vec![conv.id()]).await.unwrap();
        user_ctx.execute_all_actions().await.unwrap();
        conv.reload(&tether).await.unwrap();
        assert!(conv.labels.iter().any(|l| l.remote_label_id == Some(LabelId::inbox())));
        assert!(!conv.labels.iter().any(|l| l.remote_label_id == Some(LabelId::spam())));
    }

}


fn conv_is_labeled(conv: &Conversation, expected_labels: impl Into<Vec<LabelId>>) {
    let mut expected_labels: Vec<_> = expected_labels.into();
    let mut actual_labels = conv
        .labels
        .iter()
        .map(|l| l.remote_label_id.clone().unwrap())
        .collect::<Vec<_>>();

    expected_labels.sort();
    actual_labels.sort();

    assert_eq!(actual_labels, expected_labels);
}
