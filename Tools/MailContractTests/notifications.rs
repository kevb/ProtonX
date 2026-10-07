// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Adapted from pinned Proton Mail SDK tests/events.rs; synthetic local SDK events.
#![cfg(feature = "protonx-native")]
use mail_api::services::proton::common::MessageId;
use mail_api::services::proton::response_data::{
    MailEvent, MessageEvent, MessageFlags, MessageMetadata,
};
use mail_common::datatypes::SystemLabelId;
use mail_common::native_notifications::NativeNotifications;
use mail_common::test_utils::init::Params;
use mail_common::test_utils::test_context::{MailTestContext, MailUserContextTestExtension};
use mail_core_api::services::proton::prelude::Label;
use mail_core_api::services::proton::{Action, EventId, LabelId, LabelType};

#[tokio::test]
async fn committed_create_not_update_import_read_spam_or_stopped() {
    let ctx = MailTestContext::new().await;
    let params = Params::default_basic();
    ctx.setup_user(params.clone()).await;
    let user = ctx.mail_user_context().await;
    let queue = user.get_service::<NativeNotifications>();
    let message = MessageMetadata {
        id: MessageId::from("synthetic-new-mail"),
        conversation_id: params.conversations[0].id.clone(),
        address_id: params.addresses[0].id.clone(),
        label_ids: vec![LabelId::inbox()],
        unread: true,
        flags: MessageFlags::RECEIVED,
        subject: "Synthetic subject".into(),
        ..MessageMetadata::test_default()
    };
    let event = |action, message: MessageMetadata| MailEvent {
        event_id: EventId::from("synthetic-event"),
        messages: Some(vec![MessageEvent {
            id: message.id.clone(),
            action,
            message: Some(message),
        }]),
        labels: None,
        conversation_counts: None,
        conversations: None,
        incoming_defaults: None,
        mail_settings: None,
        message_counts: None,
        refresh: 0,
        has_more: false,
    };
    // Actual SDK transaction, not list-diff inference. Starting never replays rows.
    user.apply_event(event(Action::Create, message.clone()))
        .await
        .unwrap();
    assert!(queue.drain(&user).await.unwrap().is_empty());
    queue.start();
    user.apply_event(event(Action::Update, message.clone()))
        .await
        .unwrap();
    assert!(queue.drain(&user).await.unwrap().is_empty());
    let mut created = message.clone();
    created.id = "synthetic-second".into();
    user.apply_event(event(Action::Create, created.clone()))
        .await
        .unwrap();
    let alerts = queue.drain(&user).await.unwrap();
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].subject, "Synthetic subject");
    user.apply_event(event(Action::Create, created.clone()))
        .await
        .unwrap();
    assert!(queue.drain(&user).await.unwrap().is_empty());
    for (id, flags, unread, labels) in [
        (
            "import",
            MessageFlags::RECEIVED | MessageFlags::IMPORTED,
            true,
            vec![LabelId::inbox()],
        ),
        (
            "read",
            MessageFlags::RECEIVED,
            false,
            vec![LabelId::inbox()],
        ),
        ("spam", MessageFlags::RECEIVED, true, vec![LabelId::spam()]),
        ("sent", MessageFlags::SENT, true, vec![LabelId::sent()]),
        (
            "trash",
            MessageFlags::RECEIVED,
            true,
            vec![LabelId::trash()],
        ),
    ] {
        let mut ignored = message.clone();
        ignored.id = id.into();
        ignored.flags = flags;
        ignored.unread = unread;
        ignored.label_ids = labels;
        user.apply_event(event(Action::Create, ignored))
            .await
            .unwrap();
    }
    assert!(queue.drain(&user).await.unwrap().is_empty());
    queue.stop();
    created.id = "synthetic-stopped".into();
    user.apply_event(event(Action::Create, created))
        .await
        .unwrap();
    assert!(queue.drain(&user).await.unwrap().is_empty());
}

#[tokio::test]
async fn custom_folder_notification_preference_is_preserved() {
    let ctx = MailTestContext::new().await;
    let mut params = Params::default_basic();
    params.labels.insert(
        LabelType::Folder,
        vec![
            Label {
                id: "notify-folder".into(),
                name: "Alerts".into(),
                label_type: LabelType::Folder,
                notify: true,
                ..Label::test_default()
            },
            Label {
                id: "quiet-folder".into(),
                name: "Quiet".into(),
                label_type: LabelType::Folder,
                notify: false,
                ..Label::test_default()
            },
        ],
    );
    ctx.setup_user(params.clone()).await;
    let user = ctx.mail_user_context().await;
    let queue = user.get_service::<NativeNotifications>();
    queue.start();
    for folder in ["notify-folder", "quiet-folder"] {
        let message = MessageMetadata {
            id: MessageId::from(folder),
            conversation_id: params.conversations[0].id.clone(),
            address_id: params.addresses[0].id.clone(),
            label_ids: vec![folder.into()],
            unread: true,
            flags: MessageFlags::RECEIVED,
            ..MessageMetadata::test_default()
        };
        user.apply_event(MailEvent {
            event_id: EventId::from(folder),
            messages: Some(vec![MessageEvent {
                id: message.id.clone(),
                action: Action::Create,
                message: Some(message),
            }]),
            labels: None,
            conversation_counts: None,
            conversations: None,
            incoming_defaults: None,
            mail_settings: None,
            message_counts: None,
            refresh: 0,
            has_more: false,
        })
        .await
        .unwrap();
    }
    assert_eq!(queue.drain(&user).await.unwrap().len(), 1);
}

#[tokio::test]
async fn v6_create_events_use_the_same_committed_notification_queue() {
    use mail_api::services::proton::response_data::{MailEventV6, MailMessageEventV6};
    let ctx = MailTestContext::new().await;
    let params = Params::default_basic();
    ctx.setup_user(params.clone()).await;
    let user = ctx.mail_user_context().await;
    let queue = user.get_service::<NativeNotifications>();
    queue.start();
    let message = MessageMetadata {
        id: "synthetic-v6".into(),
        conversation_id: params.conversations[0].id.clone(),
        address_id: params.addresses[0].id.clone(),
        label_ids: vec![LabelId::inbox()],
        unread: true,
        flags: MessageFlags::RECEIVED,
        ..MessageMetadata::test_default()
    };
    ctx.mock_server().reset().await;
    ctx.mock_get_message_metadata_page(vec![message.clone()], None, None, 50, 1, 1)
        .await;
    ctx.mock_get_messages_count(None, 1).await;
    ctx.mock_get_conversations_count(None, 1).await;
    user.apply_mail_event_v6(MailEventV6 {
        event_id: "synthetic-v6-event".into(),
        labels: None,
        conversations: None,
        incoming_defaults: None,
        mail_settings: None,
        messages: Some(vec![MailMessageEventV6 {
            id: message.id.clone(),
            action: Action::Create,
        }]),
        refresh: false,
        has_more: false,
    })
    .await
    .unwrap();
    assert_eq!(queue.drain(&user).await.unwrap().len(), 1);
}

#[tokio::test]
async fn enabled_category_notify_and_disabled_category_primary_rules() {
    use mail_core_common::datatypes::SystemLabel;
    use mail_stash::orm::Model;
    let ctx = MailTestContext::new().await;
    let params = Params::default_basic();
    ctx.setup_user(params.clone()).await;
    let user = ctx.mail_user_context().await;
    let queue = user.get_service::<NativeNotifications>();
    let mut tether = user.user_stash().connection();
    let mut settings = mail_common::models::MailSettings::get_or_default(&tether).await;
    settings.mail_category_view = true;
    tether
        .write_tx(async |tx| settings.save(tx).await)
        .await
        .unwrap();
    let category = SystemLabel::CategorySocial
        .local_id(&tether)
        .await
        .unwrap()
        .unwrap();
    let mut label = mail_core_common::models::Label::load(category, &tether)
        .await
        .unwrap()
        .unwrap();
    for (name, display, notify, expected) in [
        ("quiet", true, false, 0),
        ("enabled", true, true, 1),
        ("disabled", false, false, 1),
    ] {
        label.display = display;
        label.notify = notify;
        tether
            .write_tx(async |tx| label.save(tx).await)
            .await
            .unwrap();
        queue.start();
        let message = MessageMetadata {
            id: MessageId::from(name),
            conversation_id: params.conversations[0].id.clone(),
            address_id: params.addresses[0].id.clone(),
            label_ids: vec![LabelId::inbox(), SystemLabel::CategorySocial.remote_id()],
            unread: true,
            flags: MessageFlags::RECEIVED,
            ..MessageMetadata::test_default()
        };
        user.apply_event(MailEvent {
            event_id: EventId::from(name),
            messages: Some(vec![MessageEvent {
                id: message.id.clone(),
                action: Action::Create,
                message: Some(message),
            }]),
            labels: None,
            conversation_counts: None,
            conversations: None,
            incoming_defaults: None,
            mail_settings: None,
            message_counts: None,
            refresh: 0,
            has_more: false,
        })
        .await
        .unwrap();
        assert_eq!(queue.drain(&user).await.unwrap().len(), expected);
    }
}
