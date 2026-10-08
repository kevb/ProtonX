// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
use super::*;
use mail_uniffi::{PaginatorSearchOptions, mail::{new_all_mail_mailbox, messages::scroller_search, mail_scroller::SearchScroller}};

pub(crate) fn valid_keywords(query: &str) -> bool {
    !query.trim().is_empty() && query.len() <= 256 && !query.chars().any(char::is_control)
}
pub(crate) fn allow_search_action(query: &Option<String>) -> Result<(), &'static str> {
    if query.is_some() { Err("action_unavailable") } else { Ok(()) }
}
impl Backend {
    pub(crate) fn search_snapshot(&mut self, query: String, more: bool) -> Result<Value, &'static str> {
        if !valid_keywords(&query) || (more && self.search_query.as_ref() != Some(&query)) { return Err("invalid_input"); }
        let user = self.user.clone().ok_or("invalid_state")?;
        if !more {
            if let Some(scroller) = self.scroller.take() { scroller.terminate(); }
            if let Some(scroller) = self.searcher.take() { scroller.terminate(); }
            self.action_state.clear_undo();
            self.thread = None; self.mailbox = None; self.folder = None;
            self.search_query = Some(query.clone());
            self.listing = Arc::new((Mutex::new(ListState::default()), Condvar::new()));
            let mailbox = sdk_result!(mail_uniffi::mail::NewAllMailMailboxResult, new_all_mail_mailbox(&user))
                .map_err(|e| session_failure(e, "search_failed"))?;
            self.folder = Some(mailbox.label_id().as_u64()); self.mailbox = Some(mailbox.clone());
            self.searcher = Some(sdk_result!(mail_uniffi::mail::messages::ScrollerSearchResult,
                block_on(scroller_search(mailbox, PaginatorSearchOptions { keywords: Some(query.clone()) }, None, Box::new(ListCallback(self.listing.clone())))))
                .map_err(|e| action_failure(e, "search_failed"))?);
        }
        let scroller: Arc<SearchScroller> = self.searcher.clone().ok_or("invalid_state")?;
        if self.listing.0.lock().unwrap().items.len() >= 1000 { return Err("page_limit"); }
        sdk_void!(mail_uniffi::mail::mail_scroller::SearchScrollerProtonxFetchPageResult,
            block_on(scroller.clone().protonx_fetch_page())).map_err(scroller_failure)?;
        // The worker has completed its remote page. Request a full local snapshot
        // and wait for that callback, including the zero-result case.
        let previous = self.listing.0.lock().unwrap().list_generation;
        sdk_void!(mail_uniffi::mail::mail_scroller::SearchScrollerGetItemsResult, scroller.clone().get_items()).map_err(scroller_failure)?;
        let deadline = Instant::now() + Duration::from_secs(5);
        let (lock, wake) = &*self.listing;
        let mut state = lock.lock().unwrap();
        while state.list_generation == previous && state.failed.is_none() && Instant::now() < deadline {
            state = wake.wait_timeout(state, deadline.saturating_duration_since(Instant::now())).unwrap().0;
        }
        if let Some(error) = state.failed { return Err(error); }
        if state.list_generation == previous { return Err("search_failed"); }
        let messages: Vec<Value> = state.items.iter().take(1000).map(threads::message_value).collect();
        drop(state);
        let has_more = sdk_result!(mail_uniffi::mail::mail_scroller::SearchScrollerHasMoreResult, block_on(scroller.has_more())).map_err(scroller_failure)?;
        let folder = self.folder.ok_or("invalid_state")?;
        let details = sdk_result!(mail_uniffi::mail::MailUserSessionAccountDetailsResult, block_on(user.account_details())).map_err(|e|session_failure(e,"session_failed"))?;
        Ok(json!({"folder":folder,"messages":messages,"loading":false,"searchQuery":query,"hasMore":has_more,"email":details.email}))
    }
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn search_is_bounded_and_actions_are_read_only() {
        assert!(valid_keywords("synthetic invoice")); assert!(valid_keywords("résumé"));
        for q in ["", "  ", "a\nBcc: b", &"x".repeat(257)] { assert!(!valid_keywords(q)); }
        assert!(allow_search_action(&None).is_ok());
        assert_eq!(allow_search_action(&Some("synthetic".into())), Err("action_unavailable"));
    }
    #[test] fn search_protocol_has_no_host_account_or_bulk_access() {
        assert!(serde_json::from_value::<Command>(json!({"method":"snapshot","keywords":"synthetic","more":false})).is_ok());
        for field in ["host", "account", "body", "include_trash", "items"] {
            let mut cmd = json!({"method":"snapshot","keywords":"synthetic","more":false}); cmd[field] = json!(true);
            assert!(serde_json::from_value::<Command>(cmd).is_err());
        }
    }
}
