// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Preserve email structure using Proton's pinned display sanitizer, not regex HTML surgery.
use mail_html_transformer::{Transformer, sanitizer::StripStyleSheets};
use mail_uniffi::mail::datatypes::MimeType;

const LIMIT: usize = 2 * 1024 * 1024;
pub const MAX_INLINE_IMAGE_BYTES: usize = 4 * 1024 * 1024;
const MAX_INLINE_IMAGES: usize = 64;

pub fn valid_cid(value: &str) -> bool {
    if value.is_empty() || value.len() > 256 {
        return false;
    }
    if !value.bytes().all(|b| {
        b.is_ascii_graphic()
            && !matches!(b, b'<' | b'>' | b'"' | b'\'' | b'\\' | b'?' | b'#' | b'/')
    }) {
        return false;
    }
    url::Url::parse(&format!("cid:{value}"))
        .ok()
        .is_some_and(|u| u.scheme() == "cid" && u.path() == value)
}

pub fn allowed_inline_mime(mime: &str) -> Option<&'static str> {
    let base = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    match base.as_str() {
        "image/png" => Some("image/png"),
        "image/jpeg" | "image/jpg" => Some("image/jpeg"),
        "image/gif" => Some("image/gif"),
        "image/webp" => Some("image/webp"),
        "image/avif" => Some("image/avif"),
        "image/heic" => Some("image/heic"),
        _ => None,
    }
}

pub fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 0x3f) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3f) as usize] as char);
        out.push(if chunk.len() > 1 { TABLE[((triple >> 6) & 0x3f) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[(triple & 0x3f) as usize] as char } else { '=' });
    }
    out
}

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
    // Preserve only ordinary remote image addresses and validated embedded CIDs
    // as inert attributes. All network resources (including CSS backgrounds/imports)
    // still pass through upstream disabling. Only the native scheme handler can
    // serve decrypted CID attachments or opted-in remote images.
    let mut remote_images = Vec::new();
    let mut inline_images = Vec::new();
    for image in html.document().select("img").map_err(|_| "message_failed")? {
        let mut attributes = image.attributes.borrow_mut();
        attributes.remove("data-protonx-remote-src");
        attributes.remove("data-protonx-cid");
        let Some(source) = attributes.get("src").map(|s| s.to_owned()) else {
            continue;
        };
        let trimmed = source.trim();
        if trimmed.len() > 4 && trimmed[..4].eq_ignore_ascii_case("cid:") {
            let cid = trimmed[4..].trim();
            if valid_cid(cid) && inline_images.len() < MAX_INLINE_IMAGES {
                inline_images.push((image.as_node().clone(), cid.to_owned()));
            }
            continue;
        }
        if let Ok(url) = url::Url::parse(trimmed) {
            if matches!(url.scheme(), "http" | "https")
                && url.host_str().is_some()
                && url.username().is_empty()
                && url.password().is_none()
                && source.len() <= 8192
            {
                remote_images.push((image.as_node().clone(), url.to_string()));
            }
        }
    }
    html.disable_content(true, true);
    for (image, source) in remote_images {
        if let Some(element) = image.as_element() {
            element.attributes.borrow_mut().insert("data-protonx-remote-src", source);
        }
    }
    for (image, cid) in inline_images {
        if let Some(element) = image.as_element() {
            element.attributes.borrow_mut().insert("data-protonx-cid", cid);
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
        assert!(html.contains("data-protonx-cid=\"private\""));
    }
    #[test]
    fn inline_cid_images_keep_only_validated_inert_cids_and_strip_forged() {
        let (_, html) = prepare(
            "<img src='cid:part1.abc@example.com'><img src='CID:ii_m3x9a'><img src='cid:bad/path'><img src='cid:bad?x=1'><img src='cid:http://evil.invalid'><img data-protonx-cid='forged_cid' src='https://example.com/pixel'>",
            MimeType::TextHtml,
        )
        .unwrap();
        let html = html.unwrap();
        assert!(html.contains("data-protonx-cid=\"part1.abc@example.com\""));
        assert!(html.contains("data-protonx-cid=\"ii_m3x9a\""));
        assert_eq!(html.matches("data-protonx-cid=").count(), 2);
        assert!(!html.contains("forged_cid"));
        assert!(!html.contains("bad/path"));
        assert!(!html.contains(" src=\"cid:"));
        assert!(valid_cid("part1.abc@example.com"));
        assert!(!valid_cid(""));
        assert!(!valid_cid("a/b"));
        assert!(!valid_cid("a?b=1"));
        assert!(!valid_cid(&"a".repeat(257)));
        assert_eq!(allowed_inline_mime("image/png"), Some("image/png"));
        assert_eq!(allowed_inline_mime("IMAGE/JPEG; charset=binary"), Some("image/jpeg"));
        assert_eq!(allowed_inline_mime("image/svg+xml"), None);
        assert_eq!(allowed_inline_mime("text/html"), None);
        assert_eq!(encode_base64(b""), "");
        assert_eq!(encode_base64(b"f"), "Zg==");
        assert_eq!(encode_base64(b"fo"), "Zm8=");
        assert_eq!(encode_base64(b"foo"), "Zm9v");
        assert_eq!(encode_base64(b"foobar"), "Zm9vYmFy");
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
