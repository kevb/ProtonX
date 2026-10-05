# Dependency license review

ProtonX and the pinned Pass CLI source are GPL-3.0-or-later. Original copyright
and license notices are preserved. No official logos or binaries are repackaged.
The local source archive contains a dependency inventory and original source;
Git workspace-root licenses omitted by Cargo vendoring are copied separately.

The following exact public Proton registry packages have no Cargo license
declaration or root license file in the downloaded packages:

| Package | Version |
| --- | --- |
| muon | 4.1.0 |
| muon-proc | 0.6.0, 0.7.0 |
| muon-rest | 0.1.0 |
| muon-test | 4.0.0 |
| muon-test-server | 0.1.3 |
| proton-os-interface | 0.3.3 |

They are published in [Proton's public Rust registry](https://rust-registry.proton.me/).
Their availability and the top-level Pass CLI GPL license do not establish the
missing package-level license declarations in this review. Some are only test
dependencies, but are included in the complete local source archive. An older
Muon fork in Proton's clients monorepo does not identify the license of these
exact versions. Do not substitute that fork's license as evidence.

**No binary or full vendored-source release is published while this is unresolved.**
Before distributing one, obtain and record the applicable license/redistribution
terms for these versions, include their notices, and review the resulting complete
inventory. Local build instructions and the ProtonX source/patch remain public.
