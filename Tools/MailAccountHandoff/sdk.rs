// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Appended to the pinned SDK's UserSession implementation by the materializer.
#[cfg(feature = "protonx-native")]
impl MailUserSession {
    /// Native-only one-use Calendar handoff. Never returns parent auth tokens or a login password.
    pub async fn protonx_calendar_handoff(&self) -> Result<(String, String, Vec<u8>), ProtonError> {
        let ctx = self.ctx()?;
        let secret = ctx.session().expose_key_secret().await.ok_or(UnexpectedError::Internal)?;
        let passphrase = secret.expose_secret().as_ref().to_vec();
        if passphrase.is_empty() || passphrase.len() > 4096 { return Err(UnexpectedError::Internal.into()); }
        let fork = match ctx.session().fork("web", "calendar").await {
            Ok(fork) => fork,
            Err(_) => { let mut passphrase = passphrase; passphrase.fill(0); return Err(UnexpectedError::Internal.into()); }
        };
        Ok((fork.selector, ctx.user_context().user_id().to_string(), passphrase))
    }
}
