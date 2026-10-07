// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Thread identity/membership and Trash visibility come from the pinned SDK.
use super::*;
use std::collections::HashSet;

pub(crate) const MAX_MESSAGES: usize = 200;
pub(crate) struct SelectedThread {
    anchor: u64,
    conversation: u64,
    items: Vec<Message>,
}
pub(crate) fn message_value(m: &Message) -> Value {
    json!({"id":m.id.as_u64(),"conversationID":m.conversation_id.as_u64(),"subject":m.subject,"sender":m.sender.address,"senderName":m.sender.name,"recipient":m.to_list.iter().map(|r|r.address.as_str()).collect::<Vec<_>>().join(", "),"date":m.time.0,"unread":m.unread,"attachments":m.num_attachments,"isDraft":m.is_draft,"canReply":m.can_reply,"isScheduled":m.is_scheduled})
}
fn valid_members(
    anchor: u64,
    conversation: u64,
    members: &[(u64, u64)],
) -> Result<(), &'static str> {
    if members.len() > MAX_MESSAGES {
        return Err("thread_too_large");
    }
    let mut ids = HashSet::new();
    if conversation == 0
        || members.is_empty()
        || !members.iter().any(|(id, _)| *id == anchor)
        || members
            .iter()
            .any(|(id, group)| *id == 0 || *group != conversation || !ids.insert(*id))
    {
        return Err("thread_failed");
    }
    Ok(())
}
fn scoped_member(
    anchor: u64,
    conversation: u64,
    listing: &[(u64, u64)],
    members: &[(u64, u64)],
    item: u64,
) -> bool {
    listing.contains(&(anchor, conversation)) && members.contains(&(item, conversation))
}
impl Backend {
    pub(crate) fn selected_message(&self, folder: u64, item: u64) -> Result<Message, &'static str> {
        if self.folder != Some(folder) {
            return Err("invalid_selection");
        }
        let list = self.listing.0.lock().unwrap();
        if let Some(message) = list.items.iter().find(|m| m.id.as_u64() == item) {
            return Ok(message.clone());
        }
        let thread = self.thread.as_ref().ok_or("invalid_selection")?;
        if !scoped_member(
            thread.anchor,
            thread.conversation,
            &list
                .items
                .iter()
                .map(|m| (m.id.as_u64(), m.conversation_id.as_u64()))
                .collect::<Vec<_>>(),
            &thread
                .items
                .iter()
                .map(|m| (m.id.as_u64(), m.conversation_id.as_u64()))
                .collect::<Vec<_>>(),
            item,
        ) {
            return Err("invalid_selection");
        }
        thread
            .items
            .iter()
            .find(|m| m.id.as_u64() == item)
            .cloned()
            .ok_or("invalid_selection")
    }
    pub(crate) fn load_thread(&mut self, folder: u64, item: u64) -> Result<Value, &'static str> {
        self.thread = None; // An unsuccessful switch cannot retain another thread's scope.
        if self.folder != Some(folder) {
            return Err("invalid_selection");
        }
        // Only a disclosed folder-list message can anchor a thread request.
        // Arbitrary conversation IDs and show-all/Trash bypasses are not accepted.
        let original = self
            .listing
            .0
            .lock()
            .unwrap()
            .items
            .iter()
            .find(|m| m.id.as_u64() == item)
            .cloned()
            .ok_or("invalid_selection")?;
        let mailbox = self.mailbox.clone().ok_or("invalid_state")?;
        let result = sdk_result!(
            mail_uniffi::mail::conversations::ConversationResult,
            block_on(mail_uniffi::mail::conversations::conversation(
                mailbox,
                original.conversation_id,
                false
            ))
        )
        .map_err(|e| action_failure(e, "thread_failed"))?
        .ok_or("thread_failed")?;
        let conversation = result.conversation.id.as_u64();
        if conversation != original.conversation_id.as_u64() {
            return Err("thread_failed");
        }
        valid_members(
            item,
            conversation,
            &result
                .messages
                .iter()
                .map(|m| (m.id.as_u64(), m.conversation_id.as_u64()))
                .collect::<Vec<_>>(),
        )?;
        let mut members = result.messages;
        members.sort_by_key(|m| (m.time.0, m.display_order, m.id.as_u64()));
        let value = json!({"thread":{"anchor":item,"conversationID":conversation,"messages":members.iter().map(message_value).collect::<Vec<_>>()}});
        if serde_json::to_vec(&value)
            .map_err(|_| "thread_failed")?
            .len()
            > 4 * 1024 * 1024
        {
            return Err("thread_too_large");
        }
        self.thread = Some(SelectedThread {
            anchor: item,
            conversation,
            items: members,
        });
        Ok(value)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn membership_is_authoritative_unique_and_bounded() {
        assert!(valid_members(11, 70, &[(11, 70), (12, 70)]).is_ok());
        for ids in [
            vec![],
            vec![(12, 70)],
            vec![(11, 70), (12, 71)],
            vec![(11, 70), (11, 70)],
            vec![(11, 70), (0, 70)],
        ] {
            assert_eq!(valid_members(11, 70, &ids), Err("thread_failed"));
        }
        assert_eq!(
            valid_members(11, 70, &vec![(11, 70); 201]),
            Err("thread_too_large")
        );
    }
    #[test]
    fn disclosed_child_requires_current_folder_anchor_and_matching_conversation() {
        assert!(scoped_member(
            11,
            70,
            &[(11, 70)],
            &[(11, 70), (12, 70)],
            12
        ));
        assert!(!scoped_member(11, 70, &[], &[(12, 70)], 12));
        assert!(!scoped_member(11, 70, &[(11, 71)], &[(12, 70)], 12));
        assert!(!scoped_member(11, 70, &[(11, 70)], &[(12, 71)], 12));
        assert!(!scoped_member(11, 70, &[(11, 70)], &[(12, 70)], 13));
    }
    #[test]
    fn thread_command_refuses_arbitrary_ids_and_visibility_overrides() {
        assert!(
            serde_json::from_value::<Request>(
                json!({"schema":1,"id":1,"command":{"method":"thread","folder":1,"item":11}})
            )
            .is_ok()
        );
        for extra in ["conversationID", "show_all", "limit"] {
            let mut value =
                json!({"schema":1,"id":1,"command":{"method":"thread","folder":1,"item":11}});
            value["command"][extra] = json!(true);
            assert!(serde_json::from_value::<Request>(value).is_err());
        }
    }
}
