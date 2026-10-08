// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Wait for the pinned SDK's genuine page operation; do not implement a new search API.
#[uniffi_export]
impl SearchScroller {
    pub async fn protonx_fetch_page(self: Arc<Self>) -> Result<(), MailScrollerError> {
        uniffi_async(async move {
            let (tx, rx) = tokio::sync::oneshot::channel();
            self.scroller.fetch_more(Some(tx)).map_err(RealProtonMailError::from)?;
            rx.await.map_err(|_| RealProtonMailError::from(MailContextError::MissingContext))?;
            Ok::<_, RealProtonMailError>(())
        }).await.map_err(Into::into)
    }
}
