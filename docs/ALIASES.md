# Hide-my-email aliases

In Mail, choose **New alias…** beneath **New message**, or use the **New email
alias** toolbar action while writing a message. In Pass, choose **Create item →
Email alias…**, or select **Email alias** in the item editor's type picker.
Both entry points open the same sheet without changing products or discarding a
Mail draft. Alias operations use the Pass account, which may need unlocking or
sign-in separately from Mail.

Give the alias a title. Proton supplies its random address suffix and forwarding
mailboxes; the title supplies an editable address prefix. Choose a suffix or
mailbox if the account offers several, optionally add a note, and choose the Pass
vault that will hold the alias. The forwarding destination is visible before
creation. These are forwarding aliases, not additional Mail sending identities.

**Create and copy alias** creates one alias and its encrypted Pass item. Only
after confirmation does the address enter the clipboard. The success view offers
**Copy again**, **View in Pass** and **Done**. The ordinary protected clipboard
lease applies: ProtonX clears its own copy after 30 seconds, and never clears a
newer copy from another app. Preview/demo aliases are synthetic, remain in memory
and never change the system clipboard.

The operation uses Proton's existing SDK encryption and single-alias API. Vault
permissions, organization restrictions, account quota and server-signed suffix
validation remain in effect. An unconfirmed creation is not retried automatically;
refresh Pass and check its aliases before attempting another. An acknowledged
creation remains successful if the following vault refresh fails. Locking or
closing the sheet prevents late results from being displayed or copied.

The first pass does not add alias disabling/deletion, forwarding-mailbox or custom
domain administration, alias contacts, or sending as an alias. Existing custom
domains and mailboxes can be selected if Proton offers them as creation options.

## Reference and validation

The protocol follows the pinned Pass SDK alias implementation and the official
Mail/Pass bridge in WebClients. Its options and encrypted creation fields are
checked by `scripts/verify-desktop-contract.py`. The SDK adapter lives in
`patches/pass-cli.patch`; it does not change the CLI's eligibility policy.

Synthetic tests cover private-input transport, bounds, prefix rules, exact preview
capability selection, SDK encryption/decryption of title/note, quota and vault
checks, changed mailbox selection, cancellation/lock, preservation of an unsaved
Mail draft, and acknowledged versus unconfirmed writes. Live account creation is
a separate acceptance check.
