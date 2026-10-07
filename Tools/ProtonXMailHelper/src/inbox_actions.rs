// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// SDK queue actions for one message or one disclosed conversation. No permanent delete or app replay.
use super::*;
use mail_uniffi::mail::datatypes::{ListActions, MoveDestination, Undo};
use mail_uniffi::mail::datatypes::system_folder::MovableSystemFolder;
use mail_uniffi::mail::messages;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action { Read, Unread, Archive, Trash, Inbox }
#[derive(Default)]
pub struct State {
    pub uncertain: bool,
    next: u64,
    undo: Option<(u64, Instant, Arc<Undo>)>,
}
pub struct Options { read: bool, unread: bool, destinations: Vec<(Action, Id)> }
impl Options {
    pub fn names(&self) -> Vec<Action> {
        let mut actions = vec![];
        if self.read { actions.push(Action::Read); }
        if self.unread { actions.push(Action::Unread); }
        actions.extend(self.destinations.iter().map(|(action, _)| *action));
        actions
    }
    fn destination(&self, action: Action) -> Option<Id> { self.destinations.iter().find(|(a, _)| *a == action).map(|(_, id)| *id) }
}
fn folder_action(name: MovableSystemFolder) -> Option<Action> {
    match name { MovableSystemFolder::Archive => Some(Action::Archive), MovableSystemFolder::Trash => Some(Action::Trash), MovableSystemFolder::Inbox => Some(Action::Inbox), _ => None }
}
pub fn available(mailbox: Arc<Mailbox>, id: Id) -> Result<Options, &'static str> {
    let actions = sdk_result!(messages::AllAvailableListActionsForMessagesResult, block_on(messages::all_available_list_actions_for_messages(mailbox.clone(), vec![id])))
        .map_err(|e| action_failure(e, "message_failed"))?;
    let list: Vec<_> = actions.visible_list_actions.into_iter().chain(actions.hidden_list_actions).collect();
    let mut options = Options { read: list.contains(&ListActions::MarkRead), unread: list.contains(&ListActions::MarkUnread), destinations: vec![] };
    if list.iter().any(|action| matches!(action, ListActions::MoveTo | ListActions::MoveToSystemFolder(_))) {
        let destinations = sdk_result!(messages::AvailableMoveToDestinationsForMessagesResult, block_on(messages::available_move_to_destinations_for_messages(mailbox, vec![id])))
            .map_err(|e| action_failure(e, "message_failed"))?;
        for destination in destinations {
            match destination {
                MoveDestination::Inbox(value) => options.destinations.push((Action::Inbox, value.local_id)),
                MoveDestination::SystemFolder(value) => if let Some(action) = folder_action(value.name) { options.destinations.push((action, value.local_id)); },
                _ => {}
            }
        }
    }
    Ok(options)
}
impl Backend {
    pub(crate) fn conversation_trash(&mut self, folder: u64, item: u64, expected: u64) -> Result<Value, &'static str> {
        if self.action_state.uncertain { return Err("action_uncertain"); }
        if self.composer.is_some() || self.folder != Some(folder) { return Err("invalid_selection"); }
        // A conversation is derived ONLY from a currently disclosed folder row.
        // The caller's expected identity is a stale-confirmation check, not authority.
        let conversation = conversation_for_row(&self.listing.0.lock().unwrap().items.iter()
            .map(|m| (m.id.as_u64(), m.conversation_id.as_u64())).collect::<Vec<_>>(), item, expected)?;
        let mailbox = self.mailbox.clone().ok_or("invalid_state")?;
        let destinations = sdk_result!(mail_uniffi::mail::conversations::AvailableMoveToDestinationsForConversationsResult,
            block_on(mail_uniffi::mail::conversations::available_move_to_destinations_for_conversations(mailbox.clone(), vec![Id::from(conversation)])))
            .map_err(|e| action_failure(e, "message_failed"))?;
        let trash = destinations.into_iter().find_map(|d| match d {
            MoveDestination::SystemFolder(value) if value.name == MovableSystemFolder::Trash => Some(value.local_id),
            _ => None,
        }).ok_or("action_unavailable")?;
        self.action_state.uncertain = true;
        self.action_state.undo = None;
        let undo = sdk_result!(mail_uniffi::mail::conversations::MoveConversationsResult,
            block_on(mail_uniffi::mail::conversations::move_conversations(mailbox, trash, vec![Id::from(conversation)])))
            .map_err(|e| action_failure(e, "action_uncertain"))?;
        self.action_state.uncertain = false;
        let token = if let Some(undo) = undo {
            self.action_state.next = self.action_state.next.checked_add(1).ok_or("invalid_state")?;
            let token = self.action_state.next;
            self.action_state.undo = Some((token, Instant::now(), undo));
            Some(token)
        } else { None };
        Ok(json!({"id":item,"conversationID":conversation,"queued":true,"undoToken":token}))
    }
    pub(crate) fn message_action(&mut self, folder: u64, item: u64, action: Action) -> Result<Value, &'static str> {
        if self.action_state.uncertain { return Err("action_uncertain"); }
        if self.composer.is_some() { return Err("invalid_selection"); }
        self.selected_message(folder, item)?;
        let mailbox = self.mailbox.clone().ok_or("invalid_state")?;
        let options = available(mailbox.clone(), Id::from(item))?;
        if !options.names().contains(&action) { return Err("action_unavailable"); }
        // Close the retry window BEFORE crossing the SDK's durable queue boundary.
        self.action_state.uncertain = true;
        self.action_state.undo = None;
        let undo = match action {
            Action::Read => { sdk_void!(mail_uniffi::errors::VoidActionResult, block_on(messages::mark_messages_read(mailbox, vec![Id::from(item)]))).map_err(|e| action_failure(e, "action_uncertain"))?; None }
            Action::Unread => { sdk_void!(mail_uniffi::errors::VoidActionResult, block_on(messages::mark_messages_unread(mailbox, vec![Id::from(item)]))).map_err(|e| action_failure(e, "action_uncertain"))?; None }
            _ => sdk_result!(messages::MoveMessagesResult, block_on(messages::move_messages(mailbox, options.destination(action).ok_or("action_unavailable")?, vec![Id::from(item)]))).map_err(|e| action_failure(e, "action_uncertain"))?,
        };
        self.action_state.uncertain = false;
        let token = if let Some(undo) = undo {
            self.action_state.next = self.action_state.next.checked_add(1).ok_or("invalid_state")?;
            let token = self.action_state.next;
            self.action_state.undo = Some((token, Instant::now(), undo));
            Some(token)
        } else { None };
        Ok(json!({"id":item,"queued":true,"undoToken":token}))
    }
    pub(crate) fn undo_action(&mut self, token: u64) -> Result<Value, &'static str> {
        if self.action_state.uncertain || self.composer.is_some() { return Err("action_uncertain"); }
        let user = self.user.clone().ok_or("invalid_state")?;
        let Some((saved, when, _)) = self.action_state.undo.as_ref() else { return Err("action_unavailable"); };
        if *saved != token || when.elapsed() > Duration::from_secs(30) { return Err("action_unavailable"); }
        let (_, _, undo) = self.action_state.undo.take().ok_or("action_unavailable")?;
        self.action_state.uncertain = true;
        sdk_void!(mail_uniffi::mail::datatypes::UndoUndoResult, block_on(undo.undo(user))).map_err(|e| action_failure(e, "action_uncertain"))?;
        self.action_state.uncertain = false;
        Ok(json!({"queued":true}))
    }
}
fn conversation_for_row(listing: &[(u64, u64)], item: u64, expected: u64) -> Result<u64, &'static str> {
    listing.iter().find(|(id, conversation)| *id == item && *conversation == expected && expected > 0)
        .map(|(_, conversation)| *conversation).ok_or("invalid_selection")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn conversation_trash_requires_disclosed_anchor_and_expected_identity() {
        assert_eq!(conversation_for_row(&[(11, 70)], 11, 70), Ok(70));
        for (listing, item, expected) in [(vec![],11,70), (vec![(11,70)],12,70), (vec![(11,70)],11,71), (vec![(11,0)],11,0)] {
            assert_eq!(conversation_for_row(&listing,item,expected), Err("invalid_selection"));
        }
        assert!(serde_json::from_value::<Request>(json!({"schema":1,"id":1,"command":{"method":"conversation_trash","folder":1,"item":11,"conversation":70}})).is_ok());
        for extra in ["items", "destination", "permanent", "show_all"] {
            let mut value = json!({"schema":1,"id":1,"command":{"method":"conversation_trash","folder":1,"item":11,"conversation":70}});
            value["command"][extra] = json!(true);
            assert!(serde_json::from_value::<Request>(value).is_err());
        }
    }
    #[test]
    fn closed_action_schema_rejects_bulk_and_permanent_deletion() {
        for method in ["delete", "permanent_delete", "all", "spam", "move"] { assert!(serde_json::from_value::<Action>(json!(method)).is_err()); }
        assert_eq!(serde_json::from_value::<Action>(json!("trash")).unwrap(), Action::Trash);
    }
    #[test]
    fn destinations_are_sdk_local_ids_and_dangerous_folders_are_omitted() {
        assert_eq!(folder_action(MovableSystemFolder::Trash), Some(Action::Trash));
        assert_eq!(folder_action(MovableSystemFolder::Archive), Some(Action::Archive));
        let options = Options { read:true, unread:false, destinations:vec![(Action::Archive, Id::from(731_u64))] };
        assert_eq!(options.names(), vec![Action::Read, Action::Archive]);
        assert_eq!(options.destination(Action::Archive).unwrap().as_u64(), 731);
        assert!(options.destination(Action::Trash).is_none());
    }
}
