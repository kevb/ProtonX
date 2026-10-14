# Mail translation

ProtonX offers on-device reading translation on macOS 15 and later. The rest of
the app retains its macOS 14 minimum. No translation subscription or API key is
required, and no Proton endpoint is added.

## Reading a message

When an opened message appears to use a language outside your understood languages,
a slim ribbon shows the detected language, the destination language and **Translate**.
Both languages can be changed. The original email stays untouched; **Show original**
and **Show translation** switch between the two readings without another request.
Dismiss closes the ribbon for that message. **Translate…** in the original reader
controls brings it back, including for messages where detection was uncertain.

Apple asks to download missing language models on first use. Unsupported language
pairs are explained in the ribbon. Failed/cancelled translation leaves the original
readable and supports an explicit retry. Messages larger than 64 KiB cannot be
translated in this version; no truncated result is silently substituted.

The translated view preserves paragraphs, literal URLs and email addresses. Links
require the same external-open confirmation as the original reader. It is a clean
text reading view: complex newsletter layouts, inline images, attachments, OCR,
subject translation and translating composed replies are not implemented.

## Language preferences

**Settings → Translation** sets the default destination and languages you understand.
Defaults come from macOS preferred languages. The ribbon's options menu offers:

- **Always translate this language:** translate opened messages automatically once
  both language models are installed. Missing models still require an explicit click.
- **I understand this language:** stop offering translation by default.
- **Never offer for this language:** suppress its automatic ribbon.

Language rules can be reset in Settings. An explicit Always rule overrides the
understood-language list; Never offer and Always are mutually exclusive. Manual
translation remains accessible when automatic offers are disabled.

Only language preferences persist. The original and translated message text stay
in the existing in-memory reader lifecycle; translations are discarded on message
change or lock. There is no mailbox-wide translation or persistent translation cache.
Apple processes text on-device; its framework may collect usage/performance metrics
excluding content. See [Security](../SECURITY.md#mail-translation).

## Implementation and validation

`MailTranslation.swift` contains bounded local language detection, preferences,
prose/literal segmentation and generation-scoped request state. The SwiftUI bridge
in `MailTranslationView.swift` uses `LanguageAvailability` and `TranslationSession`,
checks batch identities/language pairs and renders native text. Native Mail retains
its original sanitized HTML and existing remote-image policy. No crypto, session,
protocol or sending behavior changes.

The synthetic preview inbox includes **Fatura bilgilendirme** for trying detection,
translation, the original toggle and language controls without an account. Tests
exercise policy and cancellation with synthetic content. A native-engine test runs
only when the Turkish/English models are already installed; it never initiates a
download or opens a permission sheet during automated tests.

Apple references: [TranslationSession](https://developer.apple.com/documentation/translation/translationsession),
[Meet the Translation API](https://developer.apple.com/videos/play/wwdc2024/10117/),
[NLLanguageRecognizer](https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer).
