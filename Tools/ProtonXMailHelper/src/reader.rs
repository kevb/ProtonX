// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Preserve email structure using Proton's pinned display sanitizer, not regex HTML surgery.
use mail_html_transformer::{Transformer, sanitizer::StripStyleSheets};
use mail_uniffi::mail::datatypes::MimeType;

const LIMIT: usize = 2 * 1024 * 1024;

pub fn prepare(raw: &str, mime: MimeType) -> Result<(String, Option<String>), &'static str> {
    if raw.len() > LIMIT {
        return Err("message_too_large");
    }
    if matches!(mime, MimeType::TextPlain) {
        return Ok((raw.to_owned(), None));
    }
    if !matches!(mime, MimeType::TextHtml) {
        return Err("message_failed");
    }
    let mut html = Transformer::new(raw);
    // Upstream's serializer is recursive. Bound depth and node count before any
    // serialization (including the text fallback) to avoid stack/resource exhaustion.
    let mut pending = vec![(html.document(), 0usize)];
    let mut count = 0usize;
    while let Some((node, depth)) = pending.pop() {
        count += 1;
        if depth > 128 || count > 50_000 {
            return Err("message_too_large");
        }
        pending.extend(node.children().map(|child| (child, depth + 1)));
    }
    html.strip_whitelist(StripStyleSheets::No);
    // Preserve only ordinary image addresses as inert attributes. All network
    // resources (including CSS backgrounds/imports) still pass through upstream
    // disabling. Only the native per-message opt-in can activate these images.
    let images: Vec<_> = html.document().select("img").map_err(|_| "message_failed")?
        .filter_map(|image| {
            let mut attributes = image.attributes.borrow_mut();
            attributes.remove("data-protonx-remote-src");
            let source = attributes.get("src")?.to_owned();
            let url = url::Url::parse(&source).ok()?;
            if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none()
                || !url.username().is_empty() || url.password().is_some() || source.len() > 8192 {
                return None;
            }
            Some((image.as_node().clone(), url.to_string()))
        }).collect();
    html.disable_content(true, true);
    for (image, source) in images {
        if let Some(element) = image.as_element() {
            element.attributes.borrow_mut().insert("data-protonx-remote-src", source);
        }
    }
    html.add_noreferrer();
    html.move_styles_to_body();
    let sanitized = html.extract_body();
    if sanitized.len() > LIMIT {
        return Err("message_too_large");
    }
    let text = html2text::from_read(sanitized.as_bytes(), 100).map_err(|_| "message_failed")?;
    if text.len() > LIMIT {
        return Err("message_too_large");
    }
    Ok((text, Some(sanitized)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_newsletter_tables_lists_quotes_and_styles() {
        let raw = "<html><head><style>.card { padding:20px; color:#202020 }</style></head><body><table class='card'><tr><td><h1>Account update</h1><p>Hello <strong>Alex</strong> &amp; Sam.</p><ul><li>One</li><li>Two</li></ul><blockquote>Earlier reply</blockquote><a href='https://example.com/help'>Help</a></td></tr></table></body></html>";
        let (text, html) = prepare(raw, MimeType::TextHtml).unwrap();
        let html = html.unwrap();
        for marker in [
            "<table",
            "<h1>",
            "<strong>",
            "<li>",
            "<blockquote>",
            "<style",
            "https://example.com/help",
        ] {
            assert!(html.contains(marker), "{marker}");
        }
        assert!(text.contains("Hello"));
        assert!(text.contains("Alex"));
        assert!(text.contains("Sam."));
    }
    #[test]
    fn removes_active_content_and_disables_image_and_css_requests() {
        let (_, html) = prepare("<script>syntheticSecret()</script><iframe src='https://example.invalid/frame'></iframe><form action='https://example.invalid/send'><input value='secret'></form><p onclick='secret()'>Safe</p><a href='javascript:secret()'>Bad link</a><img src='https://example.invalid/pixel'><img src='cid:private'><div style='background:url(https://example.invalid/css)'>Body</div><style>@import url(https://example.invalid/font);</style>", MimeType::TextHtml).unwrap();
        let html = html.unwrap();
        for marker in [
            "<script",
            "<iframe",
            "<form",
            "<input",
            "onclick=",
            "javascript:",
            " src=\"https://",
            "src=\"cid:",
            "url(https://",
        ] {
            assert!(!html.contains(marker), "{marker}: {html}");
        }
        assert!(html.contains("Safe"));
    }
    #[test]
    fn image_opt_in_keeps_only_inert_credential_free_http_images() {
        let (_, html) = prepare("<img src='https://example.com/a?x=1&amp;y=2'><img src='http://example.com/b'><img src='cid:private'><img src='data:image/png,abc'><img src='https://user:password@example.com/x'><img src='javascript:bad()'><img data-protonx-remote-src='https://example.com/forged'><div style='background:url(https://example.com/css)'>Safe</div>", MimeType::TextHtml).unwrap();
        let html = html.unwrap();
        assert!(html.contains("data-protonx-remote-src=\"https://example.com/a?x=1&amp;y=2\""));
        assert!(html.contains("data-protonx-remote-src=\"http://example.com/b\""));
        assert_eq!(html.matches("data-protonx-remote-src=").count(), 2);
        assert!(!html.contains(" src=\"https://"));
        assert!(!html.contains("example.com/css"));
        assert!(!html.contains("example.com/forged"));
    }
    #[test]
    fn plaintext_is_literal_and_malformed_html_is_normalized() {
        let raw = "<script>literal text</script>\n # Not markdown\n_____\n";
        assert_eq!(
            prepare(raw, MimeType::TextPlain).unwrap(),
            (raw.into(), None)
        );
        assert!(
            prepare("<table><tr><td><b>Broken &amp; safe", MimeType::TextHtml)
                .unwrap()
                .1
                .unwrap()
                .contains("Broken &amp; safe")
        );
    }
    #[test]
    fn refuses_deep_or_oversized_documents_before_serialization() {
        assert!(
            prepare(
                &format!("{}x{}", "<div>".repeat(140), "</div>".repeat(140)),
                MimeType::TextHtml
            )
            .is_err()
        );
        assert!(prepare(&"x".repeat(LIMIT + 1), MimeType::TextPlain).is_err());
    }
}
