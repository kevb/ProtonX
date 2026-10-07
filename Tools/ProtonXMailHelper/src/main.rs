// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Account authentication and message decryption remain in Proton's pinned SDK.
#![recursion_limit = "256"]
mod protocol;
mod reader;
#[cfg(feature = "secure-storage")]
mod secure_storage;

use futures::executor::block_on;
use mail_account_uniffi::login::{LoginError, LoginFlow, TfaMethods};
use mail_issue_reporter_service::IssueReportKeys;
use mail_issue_reporter_service_uniffi::{IssueLevel, IssueReporter};
use mail_uniffi::core::datatypes::{ApiConfig, AppDetails, Id};
use mail_uniffi::core::verification::{
    ChallengeNotifier, ChallengePayload, ChallengeResponse, ChallengeServer,
};
use mail_uniffi::core::{OSKeyChain, OSKeyChainEntryKind, OSKeyChainError, StoredSessionState};
use mail_uniffi::errors::{ActionError, MailScrollerError, ProtonError, UserSessionError};
use mail_uniffi::mail::datatypes::{Message, MimeType};
use mail_uniffi::mail::draft::observer::{DraftSendResultOrigin, DraftSendStatus};
use mail_uniffi::mail::draft::recipients::{
    AddSingleRecipientError, ComposerRecipient, ComposerRecipientList, RemoveRecipientError,
    SingleRecipientEntry,
};
use mail_uniffi::mail::draft::{self, Draft, DraftCreateMode};
use mail_uniffi::mail::mail_scroller::{
    MessageScroller, MessageScrollerListUpdate, MessageScrollerLiveQueryCallback,
    MessageScrollerStatusUpdate, MessageScrollerUpdate,
};
use mail_uniffi::mail::messages::{get_message_body, scroll_messages_for_label};
use mail_uniffi::mail::sidebar::Sidebar;
use mail_uniffi::mail::{
    MailSession, MailSessionParams, MailUserSession, Mailbox, Origin, create_mail_session,
    new_inbox_mailbox, new_mailbox,
};
use mail_uniffi_common::errors::UserApiServiceError;
use security_framework::passwords::{
    delete_generic_password, get_generic_password, set_generic_password,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::{
    Arc, Condvar, Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

macro_rules! sdk_result {
    ($kind:path, $value:expr) => {{
        use $kind as Outcome;
        match $value {
            Outcome::Ok(value) => Ok(value),
            Outcome::Error(error) => Err(error),
        }
    }};
}
macro_rules! sdk_void {
    ($kind:path, $value:expr) => {{
        use $kind as Outcome;
        match $value {
            Outcome::Ok => Ok(()),
            Outcome::Error(error) => Err(error),
        }
    }};
}

mod inbox_actions;
mod threads;

const MAX_INPUT: usize = 64 * 1024;
const MAX_OUTPUT: usize = 8 * 1024 * 1024;
const KEYCHAIN_SERVICE: &str = "org.kevb.ProtonX.Mail.Native";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    schema: u8,
    id: u64,
    command: Command,
}
#[derive(Deserialize)]
#[serde(tag = "method", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Initialize,
    NotificationsStart,
    NotificationsPoll,
    NotificationsStop,
    Restore,
    Login {
        username: String,
        password: String,
    },
    Totp {
        code: String,
    },
    MailboxPassword {
        password: String,
    },
    Snapshot {
        folder: Option<u64>,
        more: bool,
        #[serde(default)]
        mode: SnapshotMode,
    },
    Message {
        folder: u64,
        item: u64,
    },
    Thread {
        folder: u64,
        item: u64,
    },
    Compose {
        mode: String,
        folder: Option<u64>,
        item: Option<u64>,
    },
    SaveDraft {
        token: u64,
        content: ComposeInput,
    },
    SendDraft {
        token: u64,
        content: ComposeInput,
    },
    DraftStatus {
        token: u64,
    },
    CloseDraft {
        token: u64,
    },
    DiscardDraft {
        token: u64,
    },
    MessageAction { folder: u64, item: u64, action: inbox_actions::Action },
    ConversationAction { folder: u64, item: u64, conversation: u64, action: inbox_actions::Action },
    UndoAction { token: u64 },
    SignOut,
}
#[derive(Clone, Copy, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum SnapshotMode {
    #[default]
    Legacy,
    Local,
    Refresh,
    Poll,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ComposeInput {
    sender: String,
    to: Vec<String>,
    cc: Vec<String>,
    bcc: Vec<String>,
    subject: String,
    text: String,
}
fn valid_address(value: &str) -> bool {
    value.len() <= 254
        && !value
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || "<>\"(),;:".contains(c))
        && value.split_once('@').is_some_and(|(local, domain)| {
            !local.is_empty()
                && !domain.contains('@')
                && domain.contains('.')
                && !domain.starts_with('.')
                && !domain.ends_with('.')
        })
}
impl ComposeInput {
    fn validate(&self, sending: bool) -> Result<(), &'static str> {
        let recipients = self
            .to
            .iter()
            .chain(&self.cc)
            .chain(&self.bcc)
            .collect::<Vec<_>>();
        if !valid_address(&self.sender)
            || recipients.len() > 100
            || (sending && recipients.is_empty())
            || recipients.iter().any(|r| !valid_address(r))
            || self.subject.len() > 998
            || self.subject.chars().any(|c| c.is_control())
            || self.text.len() > 32 * 1024
        {
            return Err("invalid_input");
        }
        let mut unique = std::collections::HashSet::new();
        if recipients.iter().any(|r| !unique.insert(r.to_lowercase())) {
            return Err("invalid_input");
        }
        Ok(())
    }
}
fn terminal_send_state(
    result: draft::observer::DraftSendResult,
    expected: Option<Id>,
) -> Option<&'static str> {
    if expected != Some(result.message_id) {
        return None;
    }
    match (result.origin, result.error) {
        (DraftSendResultOrigin::Send, DraftSendStatus::Success { .. }) => Some("sent"),
        (
            DraftSendResultOrigin::Send | DraftSendResultOrigin::SaveBeforeSend,
            DraftSendStatus::Failure(_),
        ) => Some("failed"),
        _ => None,
    }
}
struct Composer {
    token: u64,
    draft: Arc<Draft>,
    suffix: String,
    text: String,
    state: &'static str,
    message_id: Option<Id>,
    warning: Option<&'static str>,
}
fn text_body(text: &str, mime: MimeType, suffix: &str) -> String {
    if matches!(mime, MimeType::TextPlain) {
        format!("{text}{suffix}")
    } else {
        let escaped = text
            .replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
            .replace('\"', "&quot;")
            .replace("\r\n", "\n")
            .replace('\r', "\n")
            .replace('\n', "<br>");
        format!("<div>{escaped}</div><br>{suffix}")
    }
}
fn recipient_addresses(list: &ComposerRecipientList) -> Result<Vec<String>, &'static str> {
    list.recipients()
        .into_iter()
        .map(|r| match r {
            ComposerRecipient::Single(r) => Ok(r.address),
            _ => Err("draft_unsupported"),
        })
        .collect()
}
fn replace_recipients(list: &ComposerRecipientList, values: &[String]) -> Result<(), &'static str> {
    let current = recipient_addresses(list)?;
    for old in &current {
        if !values.iter().any(|v| v.eq_ignore_ascii_case(old)) {
            if !matches!(list.remove_single_recipient(old), RemoveRecipientError::Ok) {
                return Err("draft_failed");
            }
        }
    }
    for value in values {
        if !current.iter().any(|v| v.eq_ignore_ascii_case(value)) {
            if !matches!(
                list.add_single_recipient(SingleRecipientEntry {
                    name: None,
                    email: value.clone()
                }),
                AddSingleRecipientError::Ok
            ) {
                return Err("draft_failed");
            }
        }
    }
    Ok(())
}
#[derive(Serialize)]
struct Response {
    schema: u8,
    id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    failure: Option<&'static str>,
}

struct NativeKeychain;
fn account(kind: OSKeyChainEntryKind) -> &'static str {
    match kind {
        OSKeyChainEntryKind::EncryptionKey => "session-encryption-key",
        OSKeyChainEntryKind::DeviceKey => "device-key",
        OSKeyChainEntryKind::PinHash => "pin-hash",
    }
}
impl OSKeyChain for NativeKeychain {
    fn store(&self, kind: OSKeyChainEntryKind, key: String) -> Result<(), OSKeyChainError> {
        set_generic_password(KEYCHAIN_SERVICE, account(kind), key.as_bytes())
            .map_err(|_| OSKeyChainError::OS("Keychain access denied".into()))
    }
    fn load(&self, kind: OSKeyChainEntryKind) -> Result<Option<String>, OSKeyChainError> {
        match get_generic_password(KEYCHAIN_SERVICE, account(kind)) {
            Ok(data) => String::from_utf8(data)
                .map(Some)
                .map_err(|_| OSKeyChainError::OS("Invalid Keychain value".into())),
            Err(e) if e.code() == -25300 => Ok(None),
            Err(_) => Err(OSKeyChainError::OS("Keychain access denied".into())),
        }
    }
    fn delete(&self, kind: OSKeyChainEntryKind) -> Result<(), OSKeyChainError> {
        match delete_generic_password(KEYCHAIN_SERVICE, account(kind)) {
            Ok(()) => Ok(()),
            Err(e) if e.code() == -25300 => Ok(()),
            Err(_) => Err(OSKeyChainError::OS("Keychain access denied".into())),
        }
    }
}
struct NoReports;
impl IssueReporter for NoReports {
    fn report(&self, _: IssueLevel, _: Option<String>, _: String, _: IssueReportKeys) {}
}
struct Verification(Arc<AtomicBool>);
#[async_trait::async_trait]
impl ChallengeNotifier for Verification {
    async fn on_challenge(
        &self,
        _: Arc<ChallengeServer>,
        _: Arc<ChallengePayload>,
    ) -> ChallengeResponse {
        self.0.store(true, Ordering::SeqCst);
        ChallengeResponse::Cancelled // Explicit unsupported challenge; no bypass or downgrade.
    }
}

fn proton_failure(error: &ProtonError, fallback: &'static str) -> &'static str {
    match error {
        ProtonError::ServerError(UserApiServiceError::Unauthorized(_)) => "session_expired",
        _ => fallback,
    }
}
fn action_failure(error: ActionError, fallback: &'static str) -> &'static str {
    match error {
        ActionError::Other(error) => proton_failure(&error, fallback),
        _ => fallback,
    }
}
fn session_failure(error: UserSessionError, fallback: &'static str) -> &'static str {
    match error {
        UserSessionError::Other(error) => proton_failure(&error, fallback),
        _ => fallback,
    }
}
fn draft_open_failure(error: mail_uniffi::errors::DraftOpenError) -> &'static str {
    match error {
        mail_uniffi::errors::DraftOpenError::Other(error) => proton_failure(&error, "draft_failed"),
        _ => "draft_failed",
    }
}
fn draft_save_failure(error: mail_uniffi::errors::DraftSaveError) -> &'static str {
    match error {
        mail_uniffi::errors::DraftSaveError::Other(error) => proton_failure(&error, "draft_failed"),
        _ => "draft_failed",
    }
}
fn scroller_failure(error: MailScrollerError) -> &'static str {
    match error {
        MailScrollerError::Other(error) => proton_failure(&error, "snapshot_failed"),
        _ => "snapshot_failed",
    }
}

#[derive(Default)]
struct ListState {
    items: Vec<Message>,
    generation: u64,
    loading: bool,
    failed: Option<&'static str>,
    received_list: bool,
    list_generation: u64,
    fresh: bool,
    invalid_list: bool,
    fetching_more: bool,
}
struct ListCallback(Arc<(Mutex<ListState>, Condvar)>);
impl MessageScrollerLiveQueryCallback for ListCallback {
    fn on_update(&self, update: MessageScrollerUpdate) {
        let (lock, wake) = &*self.0;
        let mut state = lock.lock().unwrap();
        match update {
            MessageScrollerUpdate::List(update) => {
                state.received_list = true;
                state.list_generation += 1;
                if state.fetching_more {
                    state.loading = false;
                    state.fetching_more = false;
                }
                match update {
                    MessageScrollerListUpdate::None { .. } => {}
                    MessageScrollerListUpdate::Append { items, .. } => state.items.extend(items),
                    MessageScrollerListUpdate::ReplaceFrom { idx, items, .. } => {
                        if (idx as usize) <= state.items.len() {
                            state.items.truncate(idx as usize);
                            state.items.extend(items);
                        } else {
                            state.failed = Some("snapshot_failed");
                            state.invalid_list = true;
                        }
                    }
                    MessageScrollerListUpdate::ReplaceBefore { idx, items, .. } => {
                        if (idx as usize) <= state.items.len() {
                            state.items.splice(..idx as usize, items);
                        } else {
                            state.failed = Some("snapshot_failed");
                            state.invalid_list = true;
                        }
                    }
                    MessageScrollerListUpdate::ReplaceRange {
                        from, to, items, ..
                    } => {
                        if from <= to && (to as usize) <= state.items.len() {
                            state.items.splice(from as usize..to as usize, items);
                        } else {
                            state.failed = Some("snapshot_failed");
                            state.invalid_list = true;
                        }
                    }
                }
                if state.items.len() > 1000 {
                    state.failed = Some("snapshot_failed");
                    state.invalid_list = true;
                    state.items.clear();
                }
            }
            MessageScrollerUpdate::Status(MessageScrollerStatusUpdate::FetchNewStart) => {
                state.loading = true;
                state.fresh = false;
            }
            MessageScrollerUpdate::Status(MessageScrollerStatusUpdate::FetchNewEnd) => {
                state.loading = false;
                state.fresh = state.failed.is_none();
            }
            MessageScrollerUpdate::Error { error } => {
                state.failed = Some(scroller_failure(error));
                state.loading = false;
                state.fetching_more = false;
                state.fresh = false;
            }
            MessageScrollerUpdate::CategoryViewChanged { .. } => {}
        }
        state.generation += 1;
        wake.notify_all();
    }
}

struct Backend {
    session: Arc<MailSession>,
    user: Option<Arc<MailUserSession>>,
    flow: Option<Arc<LoginFlow>>,
    verification: Arc<AtomicBool>,
    mailbox: Option<Arc<Mailbox>>,
    scroller: Option<Arc<MessageScroller>>,
    listing: Arc<(Mutex<ListState>, Condvar)>,
    folder: Option<u64>,
    composer: Option<Composer>,
    next_composer: u64,
    action_state: inbox_actions::State,
    thread: Option<threads::SelectedThread>,
}
impl Backend {
    fn new(directory: PathBuf) -> Result<Self, &'static str> {
        let verification = Arc::new(AtomicBool::new(false));
        let path = |name: &str| directory.join(name).to_string_lossy().into_owned();
        let session = sdk_result!(
            mail_uniffi::mail::CreateMailSessionResult,
            create_mail_session(
                MailSessionParams {
                    origin: Origin::App,
                    session_dir: path("sessions"),
                    user_dir: path("users"),
                    mail_cache_dir: path("cache"),
                    mail_cache_size: 128 * 1024 * 1024,
                    log_dir: path("diagnostics"),
                    log_debug: false,
                    api_env_config: Some(ApiConfig {
                        user_agent: protocol::USER_AGENT.into(),
                        ..Default::default()
                    }),
                    app_details: AppDetails {
                        platform: "macos".into(),
                        product: "mail".into(),
                        version: format!(
                            "{}+id{}",
                            protocol::WEB_VERSION,
                            protocol::DESKTOP_VERSION
                        )
                    },
                    quarantine_xattr_app_name: Some("ProtonX".into()),
                    event_poll_duration_seconds: Some(60),
                    enable_content_search: false,
                },
                Box::new(NativeKeychain),
                Some(Arc::new(Verification(verification.clone()))),
                None,
                Arc::new(NoReports)
            )
        )
        .map_err(|_| "initialization_failed")?;
        Ok(Self {
            session,
            user: None,
            flow: None,
            verification,
            mailbox: None,
            scroller: None,
            listing: Arc::new((Mutex::new(ListState::default()), Condvar::new())),
            folder: None,
            composer: None,
            next_composer: 0,
            action_state: inbox_actions::State::default(),
            thread: None,
        })
    }
    fn login_failure(&self, error: LoginError) -> &'static str {
        if self.verification.swap(false, Ordering::SeqCst) {
            return "verification_required";
        }
        match error {
            LoginError::Incorrect2FACode => "incorrect_code",
            LoginError::CantUnlockUserKey => "mailbox_password_rejected",
            LoginError::InvalidCredentials => "sign_in_rejected",
            LoginError::NoLogin
            | LoginError::NoAddress
            | LoginError::PostLoginValidationFailed(_) => "account_unavailable",
            _ => "sign_in_failed",
        }
    }
    fn finish_login(&mut self) -> Result<Value, &'static str> {
        let flow = self.flow.clone().ok_or("invalid_state")?;
        if flow.is_awaiting_2fa() {
            let methods = sdk_result!(
                mail_account_uniffi::login::LoginFlowTfaMethodsResult,
                block_on(flow.tfa_methods())
            )
            .map_err(|e| self.login_failure(e))?;
            return Ok(
                json!({"phase": if matches!(methods,TfaMethods::Fido2) { "security_key" } else { "totp" }}),
            );
        }
        if flow.is_awaiting_mailbox_password() {
            return Ok(json!({"phase":"mailbox_password"}));
        }
        if flow.is_awaiting_new_password() {
            return Err("password_change_required");
        }
        if !flow.is_logged_in() {
            return Err("invalid_state");
        }
        let user = sdk_result!(
            mail_uniffi::mail::MailSessionToUserSessionResult,
            block_on(self.session.to_user_session(flow))
        )
        .map_err(|_| "session_failed")?;
        let id = sdk_result!(
            mail_uniffi::mail::MailUserSessionUserIdResult,
            user.user_id()
        )
        .map_err(|_| "session_failed")?;
        sdk_void!(
            mail_uniffi::errors::VoidSessionResult,
            block_on(self.session.set_primary_account(id))
        )
        .map_err(|_| "session_failed")?;
        self.user = Some(user);
        self.flow = None;
        Ok(json!({"phase":"connected", "cacheFirst":cfg!(feature = "secure-storage")}))
    }
    fn handle(&mut self, command: Command) -> Result<Value, &'static str> {
        match command {
            Command::NotificationsStart | Command::NotificationsPoll | Command::NotificationsStop => {
                let user = self.user.clone().ok_or("invalid_state")?;
                let operation = match command { Command::NotificationsStop => 0, Command::NotificationsStart => 1, _ => 2 };
                let notifications = block_on(user.protonx_notifications(operation)).map_err(|e| proton_failure(&e, "snapshot_failed"))?;
                let sidebar = Sidebar::new(&user);
                let systems = sdk_result!(mail_uniffi::mail::sidebar::SidebarSystemLabelsResult, block_on(sidebar.system_labels()))
                    .map_err(|e| action_failure(e, "snapshot_failed"))?;
                let unread = systems.iter().find(|f| inbox_actions::folder_kind(&f.description) == "inbox").map(|f| f.count).unwrap_or(0);
                Ok(json!({"notifications":notifications, "unreadCount":unread}))
            }
            Command::Initialize => {
                let sessions = sdk_result!(
                    mail_uniffi::mail::MailSessionGetSessionsResult,
                    block_on(self.session.get_sessions())
                )
                .map_err(|_| "session_failed")?;
                Ok(
                    json!({"phase":if sessions.iter().any(|s| matches!(s.state(),StoredSessionState::Authenticated)) {"locked"}else{"welcome"}}),
                )
            }
            Command::Restore => {
                let sessions = sdk_result!(
                    mail_uniffi::mail::MailSessionGetSessionsResult,
                    block_on(self.session.get_sessions())
                )
                .map_err(|_| "session_failed")?;
                let mut authenticated = sessions
                    .into_iter()
                    .filter(|s| matches!(s.state(), StoredSessionState::Authenticated));
                let saved = authenticated.next().ok_or("session_expired")?;
                if authenticated.next().is_some() {
                    return Err("invalid_state");
                } // Account switching is not implemented.
                self.user = Some(
                    sdk_result!(
                        mail_uniffi::mail::MailSessionUserSessionFromStoredSessionResult,
                        block_on(self.session.user_session_from_stored_session(saved))
                    )
                    .map_err(|e| session_failure(e, "session_failed"))?,
                );
                Ok(json!({"phase":"connected", "cacheFirst":cfg!(feature = "secure-storage")}))
            }
            Command::Login { username, password } => {
                if self.user.is_some() {
                    return Err("invalid_state");
                }
                if username.trim().is_empty()
                    || username.len() > 320
                    || password.is_empty()
                    || password.len() > 8192
                {
                    return Err("invalid_input");
                }
                self.verification.store(false, Ordering::SeqCst);
                let flow = sdk_result!(
                    mail_uniffi::mail::MailSessionNewLoginFlowResult,
                    block_on(self.session.new_login_flow())
                )
                .map_err(|_| "sign_in_failed")?;
                self.flow = Some(flow.clone());
                sdk_void!(
                    mail_account_uniffi::login::LoginFlowLoginResult,
                    block_on(flow.login(username, password, None))
                )
                .map_err(|e| self.login_failure(e))?;
                self.finish_login()
            }
            Command::Totp { code } => {
                if !(6..=8).contains(&code.len()) || !code.bytes().all(|b| b.is_ascii_digit()) {
                    return Err("invalid_input");
                }
                let flow = self.flow.clone().ok_or("invalid_state")?;
                sdk_void!(
                    mail_account_uniffi::login::LoginFlowSubmitTotpResult,
                    block_on(flow.submit_totp(code))
                )
                .map_err(|e| self.login_failure(e))?;
                self.finish_login()
            }
            Command::MailboxPassword { password } => {
                if password.is_empty() || password.len() > 8192 {
                    return Err("invalid_input");
                }
                let flow = self.flow.clone().ok_or("invalid_state")?;
                sdk_void!(
                    mail_account_uniffi::login::LoginFlowSubmitMailboxPasswordResult,
                    block_on(flow.submit_mailbox_password(password))
                )
                .map_err(|e| self.login_failure(e))?;
                self.finish_login()
            }
            Command::Snapshot { folder, more, mode } => self.snapshot(folder, more, mode),
            Command::Thread { folder, item } => self.load_thread(folder, item),
            Command::Message { folder, item } => {
                self.selected_message(folder, item)?;
                let mailbox = self.mailbox.as_ref().ok_or("invalid_state")?;
                let message = sdk_result!(
                    mail_uniffi::mail::messages::GetMessageBodyResult,
                    block_on(get_message_body(mailbox, Id::from(item)))
                )
                .map_err(|e| action_failure(e, "message_failed"))?;
                if message.failed_to_decrypt() {
                    return Err("decryption_failed");
                }
                let raw = message.raw_body();
                if raw.len() > 2 * 1024 * 1024 {
                    return Err("message_too_large");
                }
                let (body, sanitized_html) = reader::prepare(&raw, message.mime_type())?;
                let actions = inbox_actions::available(mailbox.clone(), Id::from(item))?.names();
                Ok(
                    json!({"id":item,"body":body,"sanitizedHTML":sanitized_html,"attachments":message.attachments().len(),"actions":actions}),
                )
            }
            Command::MessageAction { folder, item, action } => self.message_action(folder, item, action),
            Command::ConversationAction { folder, item, conversation, action } => self.conversation_action(folder, item, conversation, action),
            Command::UndoAction { token } => self.undo_action(token),
            Command::Compose { mode, folder, item } => self.compose(&mode, folder, item),
            Command::SaveDraft { token, content } => {
                self.update_draft(token, content, false)?;
                let draft = self.composer.as_ref().ok_or("invalid_state")?.draft.clone();
                sdk_void!(
                    mail_uniffi::errors::VoidDraftSaveResult,
                    block_on(draft.save())
                )
                .map_err(draft_save_failure)?;
                self.composer_value()
            }
            Command::SendDraft { token, content } => {
                self.update_draft(token, content, true)?;
                let composer = self.composer.as_mut().ok_or("invalid_state")?;
                // Commit the no-retry guard before crossing the SDK queue boundary.
                composer.state = "unknown";
                if let Err(error) = sdk_void!(
                    mail_uniffi::errors::VoidDraftSendResult,
                    block_on(composer.draft.clone().send())
                ) {
                    use mail_uniffi::errors::{DraftSendError, DraftSendErrorReason};
                    if matches!(
                        error,
                        DraftSendError::Reason(
                            DraftSendErrorReason::NoRecipients
                                | DraftSendErrorReason::RecipientEmailInvalid(_)
                                | DraftSendErrorReason::ProtonRecipientDoesNotExist(_)
                                | DraftSendErrorReason::AddressDisabled(_)
                                | DraftSendErrorReason::AddressDoesNotHavePrimaryKey(_)
                        )
                    ) {
                        composer.state = "editing";
                        return Err("send_rejected");
                    }
                    return Err("send_uncertain");
                }
                composer.message_id = sdk_result!(
                    draft::DraftMessageIdResult,
                    block_on(composer.draft.clone().message_id())
                )
                .map_err(|_| "send_uncertain")?;
                composer.state = "queued";
                self.draft_status(token)
            }
            Command::DraftStatus { token } => self.draft_status(token),
            Command::CloseDraft { token } => {
                let composer = self.composer.as_ref().ok_or("invalid_state")?;
                if composer.token != token {
                    return Err("invalid_state");
                }
                self.composer = None;
                Ok(json!({"closed":true}))
            }
            Command::DiscardDraft { token } => {
                let composer = self.composer.as_ref().ok_or("invalid_state")?;
                if composer.token != token || composer.state != "editing" {
                    return Err("invalid_state");
                }
                sdk_void!(
                    mail_uniffi::errors::VoidDraftDiscardResult,
                    block_on(composer.draft.clone().discard())
                )
                .map_err(|_| "draft_failed")?;
                self.composer = None;
                Ok(json!({"closed":true}))
            }
            Command::SignOut => {
                let user = self.user.as_ref().ok_or("invalid_state")?;
                let id = sdk_result!(
                    mail_uniffi::mail::MailUserSessionUserIdResult,
                    user.user_id()
                )
                .map_err(|_| "session_failed")?;
                sdk_void!(
                    mail_uniffi::errors::VoidSessionResult,
                    block_on(self.session.logout_account(id))
                )
                .map_err(|_| "sign_out_failed")?;
                self.user = None;
                self.thread = None;
                self.mailbox = None;
                self.scroller = None;
                self.flow = None;
                self.composer = None;
                self.listing.0.lock().unwrap().items.clear();
                Ok(json!({"phase":"welcome"}))
            }
        }
    }
    fn compose(
        &mut self,
        mode: &str,
        folder: Option<u64>,
        item: Option<u64>,
    ) -> Result<Value, &'static str> {
        if self.composer.is_some() {
            return Err("invalid_state");
        }
        if !matches!(mode, "new" | "open" | "reply" | "reply_all") {
            return Err("invalid_input");
        }
        let user = self.user.clone().ok_or("invalid_state")?;
        if mode != "new" {
            let item = item.ok_or("invalid_selection")?;
            let original = self.selected_message(folder.ok_or("invalid_selection")?, item)?;
            if mode == "open" {
                if !original.is_draft || original.is_scheduled {
                    return Err("draft_unsupported");
                }
            } else if !original.can_reply {
                return Err("draft_unsupported");
            }
        }
        let draft = if mode == "open" {
            sdk_result!(
                draft::OpenDraftResult,
                block_on(draft::open_draft(&user, Id::from(item.unwrap())))
            )
            .map_err(draft_open_failure)?
            .draft
        } else {
            let mode = match mode {
                "new" => DraftCreateMode::Empty,
                "reply" => DraftCreateMode::Reply(Id::from(item.unwrap())),
                "reply_all" => DraftCreateMode::ReplyAll(Id::from(item.unwrap())),
                _ => return Err("invalid_input"),
            };
            sdk_result!(
                draft::NewDraftResult,
                block_on(draft::new_draft(&user, mode))
            )
            .map_err(draft_open_failure)?
        };
        let warning = if draft.address_validation_result().is_some() {
            Some("sender_changed")
        } else {
            None
        };
        let raw = draft.body();
        if raw.len() > 2 * 1024 * 1024 {
            return Err("message_too_large");
        }
        let (text, suffix) = if mode == "open" {
            let text = if matches!(draft.mime_type(), MimeType::TextPlain) {
                raw
            } else {
                html2text::from_read(raw.as_bytes(), 100).map_err(|_| "draft_failed")?
            };
            if text.len() > 32 * 1024 {
                return Err("message_too_large");
            }
            (text, String::new())
        } else {
            (String::new(), raw)
        };
        self.next_composer += 1;
        self.composer = Some(Composer {
            token: self.next_composer,
            draft,
            suffix,
            text,
            state: "editing",
            message_id: None,
            warning,
        });
        let result = self.composer_value();
        if result.is_err() {
            self.composer = None;
        }
        result
    }
    fn composer_value(&self) -> Result<Value, &'static str> {
        let c = self.composer.as_ref().ok_or("invalid_state")?;
        let senders = sdk_result!(
            draft::DraftListSenderAddressesResult,
            block_on(c.draft.clone().list_sender_addresses())
        )
        .map_err(|e| proton_failure(&e, "draft_failed"))?;
        if !senders.available.contains(&senders.active) {
            return Err("sender_unavailable");
        }
        let quote = if matches!(c.draft.mime_type(), MimeType::TextPlain) {
            c.suffix.clone()
        } else {
            html2text::from_read(c.suffix.as_bytes(), 100).map_err(|_| "draft_failed")?
        };
        Ok(
            json!({"draft":{"token":c.token,"sender":senders.active,"senders":senders.available,"to":recipient_addresses(&c.draft.to_recipients())?,"cc":recipient_addresses(&c.draft.cc_recipients())?,"bcc":recipient_addresses(&c.draft.bcc_recipients())?,"subject":c.draft.subject(),"text":c.text,"quote":quote,"state":c.state,"warning":c.warning,"attachments":sdk_result!(draft::attachments::AttachmentListAttachmentsResult, block_on(c.draft.attachment_list().attachments())).map_err(|_| "draft_failed")?.len()}}),
        )
    }
    fn update_draft(
        &mut self,
        token: u64,
        content: ComposeInput,
        sending: bool,
    ) -> Result<(), &'static str> {
        content.validate(sending)?;
        let c = self.composer.as_mut().ok_or("invalid_state")?;
        if c.token != token || c.state != "editing" {
            return Err("invalid_state");
        }
        let senders = sdk_result!(
            draft::DraftListSenderAddressesResult,
            block_on(c.draft.clone().list_sender_addresses())
        )
        .map_err(|_| "draft_failed")?;
        if !senders.available.contains(&content.sender) {
            return Err("sender_unavailable");
        }
        if senders.active != content.sender {
            // Native batches save explicitly. Let the core update only its own
            // signature/quote; user text is preserved separately until the full
            // validated body is applied below. No HTML string surgery is needed.
            sdk_void!(
                mail_uniffi::errors::VoidDraftSaveResult,
                c.draft.set_body(c.suffix.clone())
            )
            .map_err(draft_save_failure)?;
            sdk_void!(
                draft::DraftChangeSenderAddressResult,
                block_on(c.draft.clone().change_sender_address(content.sender))
            )
            .map_err(|_| "sender_unavailable")?;
            c.suffix = c.draft.body();
            c.warning = None;
        }
        replace_recipients(&c.draft.to_recipients(), &content.to)?;
        replace_recipients(&c.draft.cc_recipients(), &content.cc)?;
        replace_recipients(&c.draft.bcc_recipients(), &content.bcc)?;
        sdk_void!(
            mail_uniffi::errors::VoidDraftSaveResult,
            c.draft.set_subject(content.subject)
        )
        .map_err(draft_save_failure)?;
        sdk_void!(
            mail_uniffi::errors::VoidDraftSaveResult,
            c.draft
                .set_body(text_body(&content.text, c.draft.mime_type(), &c.suffix))
        )
        .map_err(draft_save_failure)?;
        c.text = content.text;
        Ok(())
    }
    fn draft_status(&mut self, token: u64) -> Result<Value, &'static str> {
        let user = self.user.clone().ok_or("invalid_state")?;
        let c = self.composer.as_mut().ok_or("invalid_state")?;
        if c.token != token {
            return Err("invalid_state");
        }
        if matches!(c.state, "queued" | "unknown") {
            if c.message_id.is_none() {
                c.message_id = sdk_result!(
                    draft::DraftMessageIdResult,
                    block_on(c.draft.clone().message_id())
                )
                .map_err(|e| proton_failure(&e, "send_uncertain"))?;
            }
            let records = sdk_result!(
                draft::observer::DraftSendResultUnseenResult,
                block_on(draft::observer::draft_send_result_unseen(&user))
            )
            .map_err(|e| proton_failure(&e, "send_uncertain"))?;
            for result in records {
                if let Some(state) = terminal_send_state(result, c.message_id) {
                    c.state = state;
                }
            }
        }
        Ok(json!({"token":token,"sendState":c.state}))
    }
    fn snapshot(
        &mut self,
        folder: Option<u64>,
        more: bool,
        mode: SnapshotMode,
    ) -> Result<Value, &'static str> {
        if mode != SnapshotMode::Legacy && !cfg!(feature = "secure-storage") {
            return Err("invalid_input");
        }
        if more && matches!(mode, SnapshotMode::Local | SnapshotMode::Poll) {
            return Err("invalid_input");
        }
        let user = self.user.clone().ok_or("invalid_state")?;
        let sidebar = Sidebar::new(&user);
        let systems = sdk_result!(
            mail_uniffi::mail::sidebar::SidebarSystemLabelsResult,
            block_on(sidebar.system_labels())
        )
        .map_err(|e| action_failure(e, "snapshot_failed"))?;
        let custom = sdk_result!(
            mail_uniffi::mail::sidebar::SidebarAllCustomFoldersResult,
            block_on(sidebar.all_custom_folders())
        )
        .map_err(|e| action_failure(e, "snapshot_failed"))?;
        let mut folders: Vec<Value> = systems
            .iter()
            .filter(|f| f.display)
            .map(|f| json!({"id":f.id.as_u64(),"name":f.name,"count":f.count,"kind":inbox_actions::folder_kind(&f.description)}))
            .collect();
        folders.extend(
            custom
                .iter()
                .map(|f| json!({"id":f.id.as_u64(),"name":f.name,"count":f.total,"kind":"other"})),
        );
        let mailbox = if let Some(id) = folder {
            if !folders.iter().any(|f| f["id"].as_u64() == Some(id)) {
                return Err("invalid_selection");
            }
            sdk_result!(
                mail_uniffi::mail::NewMailboxResult,
                new_mailbox(&user, Id::from(id))
            )
        } else {
            sdk_result!(
                mail_uniffi::mail::NewInboxMailboxResult,
                new_inbox_mailbox(&user)
            )
        }
        .map_err(|_| "snapshot_failed")?;
        let selected = mailbox.label_id().as_u64();
        let changed = self.folder != Some(selected);
        if changed {
            self.thread = None;
            self.scroller = None;
            self.mailbox = Some(mailbox.clone());
            self.folder = Some(selected);
            self.listing = Arc::new((
                Mutex::new(ListState {
                    loading: mode == SnapshotMode::Legacy,
                    ..Default::default()
                }),
                Condvar::new(),
            ));
            self.scroller = Some(
                sdk_result!(
                    mail_uniffi::mail::messages::ScrollMessagesForLabelResult,
                    block_on(scroll_messages_for_label(
                        mailbox,
                        None,
                        Box::new(ListCallback(self.listing.clone()))
                    ))
                )
                .map_err(|_| "snapshot_failed")?,
            );
        }
        let scroller = self.scroller.as_ref().ok_or("invalid_state")?.clone();
        let (previous, previous_list) = {
            let mut state = self.listing.0.lock().unwrap();
            if matches!(mode, SnapshotMode::Legacy | SnapshotMode::Refresh) {
                state.failed = None;
            }
            (state.generation, state.list_generation)
        };
        if mode == SnapshotMode::Local {
            // SDK refresh reads the local database. Its paginator can independently
            // sync in the background; do not put a remote fetch ahead of this read.
            sdk_void!(
                mail_uniffi::mail::mail_scroller::MessageScrollerForceRefreshResult,
                scroller.force_refresh()
            )
            .map_err(scroller_failure)?;
        } else if mode == SnapshotMode::Poll {
            // Read callback state only. Status polling must not queue more requests.
        } else if more {
            if self.listing.0.lock().unwrap().items.len() >= 1000 {
                return Err("page_limit");
            }
            if mode != SnapshotMode::Legacy {
                let mut state = self.listing.0.lock().unwrap();
                state.fetching_more = true;
                state.loading = true;
            }
            sdk_void!(
                mail_uniffi::mail::mail_scroller::MessageScrollerFetchMoreResult,
                scroller.fetch_more()
            )
            .map_err(scroller_failure)?;
        } else if !self.listing.0.lock().unwrap().loading || mode == SnapshotMode::Legacy {
            {
                let mut state = self.listing.0.lock().unwrap();
                state.loading = true;
                state.fresh = false;
            }
            sdk_void!(
                mail_uniffi::mail::mail_scroller::MessageScrollerFetchNewResult,
                scroller.fetch_new()
            )
            .map_err(scroller_failure)?;
        }
        let deadline = Instant::now()
            + if mode == SnapshotMode::Legacy {
                Duration::from_secs(5)
            } else {
                Duration::from_millis(150)
            };
        let (lock, wake) = &*self.listing;
        let mut state = lock.lock().unwrap();
        while (if mode == SnapshotMode::Legacy {
            state.generation == previous || state.loading
        } else if mode == SnapshotMode::Local {
            state.list_generation == previous_list
        } else {
            !state.received_list
        }) && state.failed.is_none()
            && Instant::now() < deadline
        {
            let remaining = deadline.saturating_duration_since(Instant::now());
            state = wake.wait_timeout(state, remaining).unwrap().0;
        }
        if let Some(failure) = state.failed {
            if mode == SnapshotMode::Legacy || failure != "snapshot_failed" || state.invalid_list {
                return Err(failure);
            }
        }
        let messages:Vec<Value>=state.items.iter().take(1000).map(threads::message_value).collect();
        let loading = state.loading || (!state.received_list && state.failed.is_none());
        let fresh =
            mode != SnapshotMode::Local && state.fresh && !loading && state.failed.is_none();
        let refresh_failed = state.failed.is_some();
        if fresh { self.action_state.uncertain = false; }
        drop(state); // Never hold a callback mutex across SDK I/O.
        let details = sdk_result!(
            mail_uniffi::mail::MailUserSessionAccountDetailsResult,
            block_on(user.account_details())
        )
        .map_err(|e| session_failure(e, "session_failed"))?;
        Ok(
            json!({"folders":folders,"folder":selected,"messages":messages,"loading":loading,"email":details.email,"fresh":fresh,"refreshFailed":refresh_failed}),
        )
    }
}

fn read_packet(reader: &mut impl BufRead) -> io::Result<Option<Vec<u8>>> {
    let mut packet = Vec::new();
    loop {
        let bytes = reader.fill_buf()?;
        if bytes.is_empty() {
            return if packet.is_empty() {
                Ok(None)
            } else {
                Err(io::ErrorKind::UnexpectedEof.into())
            };
        }
        let take = bytes
            .iter()
            .position(|b| *b == b'\n')
            .map(|p| p + 1)
            .unwrap_or(bytes.len());
        if packet.len() + take > MAX_INPUT {
            return Err(io::ErrorKind::InvalidData.into());
        }
        packet.extend_from_slice(&bytes[..take]);
        reader.consume(take);
        if packet.last() == Some(&b'\n') {
            packet.pop();
            return Ok(Some(packet));
        }
    }
}
fn main() {
    // No inherited account/debug/proxy configuration; Swift supplies only this profile path.
    std::panic::set_hook(Box::new(|_| {}));
    unsafe {
        libc_umask();
    }
    let Some(directory) = std::env::var_os("PROTONX_MAIL_DIR").map(PathBuf::from) else {
        std::process::exit(2)
    };
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let stdout = io::stdout();
    let mut writer = stdout.lock();
    let mut backend: Option<Backend> = None;
    let mut storage_guard = None;
    while let Ok(Some(packet)) = read_packet(&mut reader) {
        let Ok(request) = serde_json::from_slice::<Request>(&packet) else {
            break;
        };
        if request.schema != 1 || request.id == 0 {
            break;
        }
        #[cfg(feature = "secure-storage")]
        let storage_ready = if storage_guard.is_none() {
            secure_storage::prepare(&directory).map(|guard| {
                storage_guard = Some(guard);
            })
        } else {
            Ok(())
        };
        #[cfg(not(feature = "secure-storage"))]
        let storage_ready = if storage_guard.is_none() {
            protonx_mail_storage::ProfileGuard::acquire(&directory)
                .and_then(|guard| {
                    guard.check_startup(false)?;
                    Ok(guard)
                })
                .map(|guard| {
                    storage_guard = Some(guard);
                })
                .map_err(|error| match error {
                    protonx_mail_storage::StorageError::MigrationPending => {
                        "storage_migration_pending"
                    }
                    protonx_mail_storage::StorageError::EncryptedProfile => {
                        "storage_version_unsupported"
                    }
                    _ => "storage_unavailable",
                })
        } else {
            Ok(())
        };
        let result = storage_ready
            .and_then(|_| {
                if backend.is_none() {
                    Backend::new(directory.clone()).map(|created| {
                        backend = Some(created);
                    })
                } else {
                    Ok(())
                }
            })
            .and_then(|_| backend.as_mut().unwrap().handle(request.command));
        let response = match result {
            Ok(value) => Response {
                schema: 1,
                id: request.id,
                result: Some(value),
                failure: None,
            },
            Err(failure) => Response {
                schema: 1,
                id: request.id,
                result: None,
                failure: Some(failure),
            },
        };
        let Ok(mut output) = serde_json::to_vec(&response) else {
            break;
        };
        if output.len() > MAX_OUTPUT {
            break;
        }
        output.push(b'\n');
        if writer
            .write_all(&output)
            .and_then(|_| writer.flush())
            .is_err()
        {
            break;
        }
    }
    drop(backend);
    // Keep the profile lock held until the OS terminates every helper thread.
    // The default SDK detaches pool workers; dropping the guard here would allow
    // another helper/migrator to enter before those workers actually exit.
    // Replies were flushed above. OS process exit releases the lock descriptor.
    std::process::exit(0);
}
unsafe fn libc_umask() {
    unsafe extern "C" {
        fn umask(mask: u16) -> u16;
    }
    unsafe {
        umask(0o077);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn protocol_refuses_unknown_fields_and_methods() {
        assert!(serde_json::from_value::<Request>(json!({"schema":1,"id":1,"command":{"method":"login","username":"test@example.com","password":"synthetic","extra":"bad"}})).is_err());
        assert!(
            serde_json::from_value::<Request>(
                json!({"schema":1,"id":1,"command":{"method":"export"}})
            )
            .is_err()
        );
    }
    #[test]
    fn snapshot_modes_are_closed_and_old_requests_default_to_legacy() {
        let parse = |mode: Option<&str>| {
            let mut command = json!({"method":"snapshot", "more":false});
            if let Some(mode) = mode {
                command["mode"] = json!(mode);
            }
            serde_json::from_value::<Command>(command)
        };
        assert!(matches!(
            parse(None).unwrap(),
            Command::Snapshot {
                mode: SnapshotMode::Legacy,
                ..
            }
        ));
        assert!(matches!(
            parse(Some("poll")).unwrap(),
            Command::Snapshot {
                mode: SnapshotMode::Poll,
                ..
            }
        ));
        assert!(parse(Some("export")).is_err());
    }
    #[test]
    fn network_failure_preserves_list_but_cannot_claim_freshness() {
        let listing = Arc::new((Mutex::new(ListState::default()), Condvar::new()));
        let callback = ListCallback(listing.clone());
        callback.on_update(MessageScrollerUpdate::Status(
            MessageScrollerStatusUpdate::FetchNewStart,
        ));
        assert!(listing.0.lock().unwrap().loading);
        callback.on_update(MessageScrollerUpdate::Error {
            error: MailScrollerError::Other(ProtonError::Network),
        });
        callback.on_update(MessageScrollerUpdate::Status(
            MessageScrollerStatusUpdate::FetchNewEnd,
        ));
        let state = listing.0.lock().unwrap();
        assert!(!state.loading);
        assert!(!state.fresh);
        assert!(!state.invalid_list);
        assert_eq!(state.failed, Some("snapshot_failed"));
    }
    #[test]
    fn framing_refuses_oversized_or_partial_credentials() {
        assert!(read_packet(&mut io::Cursor::new(vec![b'x'; MAX_INPUT + 1])).is_err());
        assert!(read_packet(&mut io::Cursor::new(b"partial")).is_err());
        assert_eq!(
            read_packet(&mut io::Cursor::new(b"{}\n")).unwrap(),
            Some(b"{}".to_vec())
        );
    }
    #[test]
    fn expired_sessions_are_distinct_from_network_errors_without_server_text() {
        let unauthorized = ProtonError::ServerError(UserApiServiceError::Unauthorized(
            "SYNTHETIC-private-server-text".into(),
        ));
        assert_eq!(
            action_failure(ActionError::Other(unauthorized), "message_failed"),
            "session_expired"
        );
        assert_eq!(
            scroller_failure(MailScrollerError::Other(ProtonError::Network)),
            "snapshot_failed"
        );
        let forbidden = ProtonError::ServerError(UserApiServiceError::Forbidden(
            "SYNTHETIC-private-server-text".into(),
        ));
        assert_eq!(
            session_failure(UserSessionError::Other(forbidden), "session_failed"),
            "session_failed"
        );
    }
    #[test]
    fn malformed_live_list_update_fails_without_panicking() {
        let listing = Arc::new((Mutex::new(ListState::default()), Condvar::new()));
        ListCallback(listing.clone()).on_update(MessageScrollerUpdate::List(
            MessageScrollerListUpdate::ReplaceRange {
                scroller_id: "synthetic".into(),
                from: 5,
                to: 2,
                items: vec![],
            },
        ));
        assert_eq!(listing.0.lock().unwrap().failed, Some("snapshot_failed"));
    }
    #[test]
    fn a_save_acknowledgement_or_another_message_never_confirms_delivery() {
        use draft::observer::{DraftSendFailure, DraftSendResult};
        use mail_uniffi::core::datatypes::UnixTimestamp;
        let record = |origin, error| DraftSendResult {
            message_id: Id::from(3_u64),
            timestamp: UnixTimestamp(0),
            origin,
            error,
        };
        let success = || DraftSendStatus::Success {
            seconds_until_cancel: 0,
            delivery_time: UnixTimestamp(0),
        };
        let failure = || DraftSendStatus::Failure(DraftSendFailure::Other(ProtonError::Network));
        assert_eq!(
            terminal_send_state(
                record(DraftSendResultOrigin::SaveBeforeSend, success()),
                Some(Id::from(3_u64))
            ),
            None
        );
        assert_eq!(
            terminal_send_state(
                record(DraftSendResultOrigin::Send, success()),
                Some(Id::from(4_u64))
            ),
            None
        );
        assert_eq!(
            terminal_send_state(
                record(DraftSendResultOrigin::Send, success()),
                Some(Id::from(3_u64))
            ),
            Some("sent")
        );
        assert_eq!(
            terminal_send_state(
                record(DraftSendResultOrigin::SaveBeforeSend, failure()),
                Some(Id::from(3_u64))
            ),
            Some("failed")
        );
        assert_eq!(
            terminal_send_state(
                record(DraftSendResultOrigin::Save, failure()),
                Some(Id::from(3_u64))
            ),
            None
        );
    }
    #[test]
    fn composer_refuses_header_injection_duplicate_addresses_and_empty_send() {
        let mut content = ComposeInput {
            sender: "alex.demo@gmail.com".into(),
            to: vec!["sam@example.com".into()],
            cc: vec![],
            bcc: vec![],
            subject: "Synthetic".into(),
            text: "Hi".into(),
        };
        assert!(content.validate(true).is_ok());
        content.subject = "Subject\r\nBcc: other@example.com".into();
        assert!(content.validate(true).is_err());
        content.subject = "Synthetic".into();
        content.cc.push("SAM@example.com".into());
        assert!(content.validate(true).is_err());
        content.cc.clear();
        content.to.clear();
        assert!(content.validate(true).is_err());
        assert!(content.validate(false).is_ok());
        content.text = "x".repeat(32 * 1024 + 1);
        assert!(content.validate(false).is_err());
        assert!(!valid_address("alex@example.com\r\nBcc: other@example.com"));
    }
    #[test]
    fn composer_escapes_user_text_and_preserves_core_signature_and_quote() {
        let suffix = "<blockquote>Encrypted upstream quote</blockquote>";
        assert_eq!(
            text_body(
                "<img src=\"https://example.invalid\">\n&",
                MimeType::TextHtml,
                suffix
            ),
            "<div>&lt;img src=&quot;https://example.invalid&quot;&gt;<br>&amp;</div><br><blockquote>Encrypted upstream quote</blockquote>"
        );
        assert_eq!(
            text_body("SYNTHETIC\n", MimeType::TextPlain, "Original quote"),
            "SYNTHETIC\nOriginal quote"
        );
    }
    #[test]
    fn composer_protocol_keeps_address_and_content_in_closed_private_payload() {
        let request = json!({"schema":1,"id":1,"command":{"method":"send_draft","token":3,"content":{"sender":"alex.demo@gmail.com","to":["sam@example.com"],"cc":[],"bcc":[],"subject":"Synthetic","text":"SYNTHETIC body"}}});
        assert!(serde_json::from_value::<Request>(request.clone()).is_ok());
        let mut injected = request;
        injected["command"]["content"]["allow_spoofing"] = json!(true);
        assert!(serde_json::from_value::<Request>(injected).is_err());
    }
    #[test]
    fn renderer_never_loads_remote_resources() {
        let html=b"<p>Synthetic note</p><img src='https://example.invalid/private'><script>secret()</script>";
        let text = html2text::from_read(&html[..], 80).unwrap();
        assert!(text.contains("Synthetic note"));
        assert!(!text.contains("secret()"));
    }
}
