// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// A bounded, read-only projection of committed SDK CREATE events. No push device,
// new API transport, persistent notification store, or crypto implementation.
use crate::datatypes::{LocalMessageId, MessageFlags};
use crate::models::{MailSettings, Message};
use crate::{AppError, MailUserContext};
use mail_core_common::datatypes::SystemLabel;
use mail_core_common::event_loop::events::Action;
use mail_core_common::models::{Label, ModelIdExtension as _};
use mail_stash::orm::Model;
use std::collections::VecDeque;
use std::sync::Mutex;

#[derive(Default)]
pub struct NativeNotifications(Mutex<State>);
#[derive(Default)]
struct State {
    armed: bool,
    pending: VecDeque<LocalMessageId>,
    seen: VecDeque<LocalMessageId>,
}
#[derive(serde::Serialize)]
pub struct NativeNotification {
    pub id: u64,
    pub folder: u64,
    pub sender: String,
    pub subject: String,
}
impl NativeNotifications {
    pub fn start(&self) {
        *self.0.lock().unwrap() = State {
            armed: true,
            ..Default::default()
        };
    }
    pub fn stop(&self) {
        *self.0.lock().unwrap() = State::default();
    }
    pub fn record(&self, ids: Vec<LocalMessageId>) {
        let mut state = self.0.lock().unwrap();
        if !state.armed {
            return;
        }
        for id in ids {
            if state.seen.contains(&id) {
                continue;
            }
            if state.seen.len() == 4096 {
                state.seen.pop_front();
            }
            state.seen.push_back(id);
            if state.pending.len() == 64 {
                state.pending.pop_front();
            }
            state.pending.push_back(id);
        }
    }
    pub fn created(action: Action) -> bool {
        action == Action::Create
    }
    pub fn eligible(unread: bool, deleted: bool, flags: MessageFlags) -> bool {
        unread
            && !deleted
            && flags.contains(MessageFlags::RECEIVED)
            && !flags.contains(MessageFlags::IMPORTED)
    }
    pub async fn drain(&self, ctx: &MailUserContext) -> Result<Vec<NativeNotification>, AppError> {
        let ids: Vec<_> = self.0.lock().unwrap().pending.drain(..).collect();
        let tether = ctx.user_stash().connection();
        let categories = MailSettings::get_or_default(&tether)
            .await
            .mail_category_view;
        let mut result = Vec::new();
        for id in ids {
            let Some(message) = Message::load(id, &tether).await? else {
                continue;
            };
            if !Self::eligible(message.unread, message.deleted, message.flags) {
                continue;
            }
            let mut labels = Vec::new();
            for remote in message.label_ids.iter().take(1024) {
                if let Some(label) = Label::find_by_remote_id(remote.clone(), &tether).await? {
                    labels.push(label);
                }
            }
            if labels.iter().any(|l| {
                matches!(
                    SystemLabel::from_opt_rid(l.remote_id.as_ref()),
                    Some(SystemLabel::Spam | SystemLabel::Trash)
                )
            }) {
                continue;
            }
            let inbox = labels.iter().find(|l| {
                SystemLabel::from_opt_rid(l.remote_id.as_ref()) == Some(SystemLabel::Inbox)
            });
            let starred = labels.iter().any(|l| {
                SystemLabel::from_opt_rid(l.remote_id.as_ref()) == Some(SystemLabel::Starred)
            });
            let inbox_allowed = inbox.is_some()
                && (!categories
                    || starred
                    || labels
                        .iter()
                        .find(|l| {
                            SystemLabel::from_opt_rid(l.remote_id.as_ref())
                                .is_some_and(|s| s.is_category())
                        })
                        .is_none_or(|l| !l.display || l.notify));
            let folder = if inbox_allowed {
                inbox
            } else {
                labels.iter().find(|l| {
                    (l.notify && l.label_type == mail_core_common::datatypes::LabelType::Folder)
                        || (starred
                            && SystemLabel::from_opt_rid(l.remote_id.as_ref())
                                == Some(SystemLabel::Starred))
                })
            };
            let Some(folder) = folder else {
                continue;
            };
            let name = message.sender.name.into_clear_text_string();
            let sender = if name.is_empty() {
                message.sender.address.into_clear_text_string()
            } else {
                name
            };
            result.push(NativeNotification {
                id: id.as_u64(),
                folder: folder.id().as_u64(),
                sender: clean(&sender, 320),
                subject: clean(&message.subject, 998),
            });
        }
        Ok(result)
    }
}
fn clean(value: &str, max: usize) -> String {
    value
        .chars()
        .filter(|c| !c.is_control())
        .take(max)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_created_received_unread_non_imported_mail_is_eligible() {
        assert!(NativeNotifications::created(Action::Create));
        for action in [Action::Delete, Action::Update, Action::UpdateFlags] {
            assert!(!NativeNotifications::created(action));
        }
        assert!(NativeNotifications::eligible(
            true,
            false,
            MessageFlags::RECEIVED
        ));
        for (unread, deleted, flags) in [
            (false, false, MessageFlags::RECEIVED),
            (true, true, MessageFlags::RECEIVED),
            (true, false, MessageFlags::SENT),
            (true, false, MessageFlags::RECEIVED | MessageFlags::IMPORTED),
        ] {
            assert!(!NativeNotifications::eligible(unread, deleted, flags));
        }
    }
    #[test]
    fn queue_is_armed_bounded_deduplicated_and_cleared() {
        let queue = NativeNotifications::default();
        queue.record(vec![1.into()]);
        assert!(queue.0.lock().unwrap().pending.is_empty());
        queue.start();
        queue.record((1..=100_u64).map(Into::into).collect());
        queue.record(vec![100.into()]);
        assert_eq!(queue.0.lock().unwrap().pending.len(), 64);
        assert_eq!(
            queue.0.lock().unwrap().pending.front().unwrap().as_u64(),
            37
        );
        queue.stop();
        assert!(queue.0.lock().unwrap().pending.is_empty());
        queue.start();
        assert!(queue.0.lock().unwrap().seen.is_empty());
    }
}
