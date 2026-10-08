// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Narrow native adapter; Proton owns attachment encryption, quota and upload jobs.
use super::*;
use mail_uniffi::mail::datatypes::AttachmentMetadata;
use mail_uniffi::mail::draft::attachments::DraftAttachmentState;
use std::fs::OpenOptions;
use std::os::unix::fs::OpenOptionsExt;
use security_framework::random::SecRandom;

pub const MAX_FILE: usize = 25_000_000;
pub const CHUNK: usize = 24 * 1024;
const MAX_ATTACHMENTS: usize = 256;

pub fn filename(value: &str) -> String {
    let name: String = value.chars().filter(|c| !c.is_control() && !matches!(c, '/' | '\\' | ':' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')).take(200).collect();
    let name = name.trim().trim_matches('.');
    if name.is_empty() { "attachment".into() } else { name.chars().scan(0, |n, c| { *n += c.len_utf8(); (*n <= 240).then_some(c) }).collect() }
}
fn metadata(a: &AttachmentMetadata, state: &str) -> Value {
    json!({"id":u64::from(a.id),"name":filename(&a.name),"size":a.size,"mime":a.mime_type.mime,"state":state})
}
pub fn message_list(list: &[AttachmentMetadata]) -> Result<Vec<Value>, &'static str> {
    if list.len() > MAX_ATTACHMENTS { return Err("attachment_failed"); }
    Ok(list.iter().filter(|a| a.is_listable).map(|a| metadata(a,"available")).collect())
}
fn hex(bytes: &[u8]) -> String { const H: &[u8] = b"0123456789abcdef"; bytes.iter().flat_map(|b| [H[(b >> 4) as usize] as char, H[(b & 15) as usize] as char]).collect() }
fn unhex(value: &str) -> Result<Vec<u8>, &'static str> {
    if value.len() > CHUNK * 2 || value.len() % 2 != 0 { return Err("attachment_transfer_invalid"); }
    value.as_bytes().chunks_exact(2).map(|c| {
        let digit = |b| match b { b'0'..=b'9' => Ok(b - b'0'), b'a'..=b'f' => Ok(b - b'a' + 10), _ => Err("attachment_transfer_invalid") };
        Ok(digit(c[0])? * 16 + digit(c[1])?)
    }).collect()
}
#[derive(Default)]
pub struct Transfers { next: u64, current: Option<Transfer> }
struct Transfer { token: u64, started: Instant, kind: Kind }
enum Kind {
    Download { folder: u64, item: u64, attachment: u64, bytes: Vec<u8>, offset: usize },
    Upload { draft: u64, name: String, size: usize, bytes: Vec<u8> },
}
impl Transfers {
    pub fn cancel(&mut self, token: u64) { if self.current.as_ref().is_some_and(|t| t.token == token) { self.clear(); } }
    pub fn clear(&mut self) { self.current = None; }
    fn start(&mut self, kind: Kind) -> u64 {
        self.next += 1; self.current = Some(Transfer { token: self.next, started: Instant::now(), kind }); self.next
    }
    fn take(&mut self, token: u64) -> Result<Transfer, &'static str> {
        let Some(t) = self.current.take() else { return Err("attachment_transfer_invalid"); };
        if t.token != token || t.started.elapsed() > Duration::from_secs(120) { return Err("attachment_transfer_invalid"); }
        Ok(t)
    }
}
// A randomly named, mode-0600 SDK staging file exists only while add() imports it.
// The source's filename never selects a local path. No file path crosses app IPC.
struct StagingFile(PathBuf);
impl Drop for StagingFile { fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); } }
fn stage(directory: &str, bytes: &[u8]) -> Result<StagingFile, &'static str> {
    let root = PathBuf::from(directory);
    if !std::fs::symlink_metadata(&root).map_err(|_| "attachment_failed")?.is_dir() { return Err("attachment_failed"); }
    let mut random = [0u8; 16]; SecRandom::default().copy_bytes(&mut random).map_err(|_| "attachment_failed")?;
    let path = root.join(format!("protonx-upload-{}", hex(&random)));
    let staged = StagingFile(path.clone());
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).map_err(|_| "attachment_failed")?;
    file.write_all(bytes).map_err(|_| "attachment_failed")?;
    file.sync_all().map_err(|_| "attachment_failed")?;
    Ok(staged)
}
impl Backend {
    pub fn attachment_metadata(&self, folder: u64, item: u64) -> Result<Value, &'static str> {
        self.selected_message(folder, item)?;
        let message = sdk_result!(mail_uniffi::mail::messages::GetMessageBodyResult, block_on(get_message_body(self.mailbox.as_ref().ok_or("invalid_state")?, Id::from(item))))
            .map_err(|e| action_failure(e, "attachment_failed"))?;
        if message.failed_to_decrypt() { return Err("decryption_failed"); }
        let attachments = message.attachments();
        if attachments.len() > MAX_ATTACHMENTS { return Err("attachment_failed"); }
        Ok(json!({"id":item,"attachmentList":attachments.iter().filter(|a| a.is_listable).map(|a| metadata(a,"available")).collect::<Vec<_>>()}))
    }
    pub fn draft_attachments(&self) -> Result<Vec<Value>, &'static str> {
        let c = self.composer.as_ref().ok_or("invalid_state")?;
        let list = sdk_result!(draft::attachments::AttachmentListAttachmentsResult, block_on(c.draft.attachment_list().attachments()))
            .map_err(|_| "attachment_failed")?;
        if list.len() > MAX_ATTACHMENTS { return Err("attachment_failed"); }
        Ok(list.iter().filter(|a| a.attachment.is_listable).map(|a| metadata(&a.attachment, match a.state {
            DraftAttachmentState::Uploaded => "uploaded", DraftAttachmentState::Uploading => "uploading",
            DraftAttachmentState::Pending => "pending", DraftAttachmentState::Offline => "offline", DraftAttachmentState::Error(_) => "failed",
        })).collect())
    }
    pub fn attachment_download(&mut self, folder: u64, item: u64, attachment: u64) -> Result<Value, &'static str> {
        self.transfers.clear();
        let metadata = self.attachment_metadata(folder, item)?;
        let known = metadata["attachmentList"].as_array().ok_or("attachment_failed")?.iter().find(|a| a["id"].as_u64() == Some(attachment)).ok_or("invalid_selection")?;
        if known["size"].as_u64().ok_or("attachment_failed")? > MAX_FILE as u64 { return Err("attachment_too_large"); }
        let bytes = block_on(self.mailbox.as_ref().ok_or("invalid_state")?.protonx_attachment_content(Id::from(attachment)))
            .map_err(|e| action_failure(e, "attachment_failed"))?;
        if bytes.len() > MAX_FILE { return Err("attachment_too_large"); }
        let size = bytes.len();
        let token = self.transfers.start(Kind::Download { folder, item, attachment, bytes, offset: 0 });
        Ok(json!({"transfer":{"token":token,"size":size,"offset":0}}))
    }
    pub fn attachment_chunk(&mut self, token: u64, folder: u64, item: u64, attachment: u64, offset: usize) -> Result<Value, &'static str> {
        self.selected_message(folder,item)?;
        let mut t = self.transfers.take(token)?;
        let Kind::Download { folder: f, item: i, attachment: a, bytes, offset: current } = &mut t.kind else { return Err("attachment_transfer_invalid"); };
        if (*f,*i,*a,*current) != (folder,item,attachment,offset) { return Err("attachment_transfer_invalid"); }
        let end = (*current + CHUNK).min(bytes.len()); let data = hex(&bytes[*current..end]); *current = end;
        let done = end == bytes.len(); let size = bytes.len();
        if !done { self.transfers.current = Some(t); }
        Ok(json!({"transfer":{"token":token,"size":size,"offset":end,"data":data,"done":done}}))
    }
    fn editable_draft(&self, token: u64) -> Result<Arc<Draft>, &'static str> {
        let c = self.composer.as_ref().ok_or("invalid_state")?;
        if c.token != token || c.state != "editing" { return Err("invalid_state"); } Ok(c.draft.clone())
    }
    pub fn upload_start(&mut self, token: u64, name: String, size: usize) -> Result<Value, &'static str> {
        self.editable_draft(token)?; self.transfers.clear();
        if size > MAX_FILE { return Err("attachment_too_large"); }
        if name != filename(&name) || name.is_empty() || name.len() > 240 { return Err("invalid_input"); }
        let transfer = self.transfers.start(Kind::Upload { draft: token, name, size, bytes: Vec::new() });
        Ok(json!({"transfer":{"token":transfer,"size":size,"offset":0}}))
    }
    pub fn upload_chunk(&mut self, token: u64, transfer: u64, offset: usize, data: String) -> Result<Value, &'static str> {
        self.editable_draft(token)?;
        let mut t = self.transfers.take(transfer)?;
        let Kind::Upload { draft, size, bytes, .. } = &mut t.kind else { return Err("attachment_transfer_invalid"); };
        let data = unhex(&data)?;
        if *draft != token || offset != bytes.len() || data.is_empty() || bytes.len() + data.len() > *size { return Err("attachment_transfer_invalid"); }
        bytes.extend(data); let offset = bytes.len(); let size = *size; self.transfers.current = Some(t);
        Ok(json!({"transfer":{"token":transfer,"size":size,"offset":offset}}))
    }
    pub fn upload_finish(&mut self, token: u64, transfer: u64) -> Result<Value, &'static str> {
        let draft = self.editable_draft(token)?;
        let t = self.transfers.take(transfer)?;
        let Kind::Upload { draft: owner, name, size, bytes } = t.kind else { return Err("attachment_transfer_invalid"); };
        if owner != token || size != bytes.len() { return Err("attachment_transfer_invalid"); }
        let list = draft.attachment_list();
        let staged = stage(&list.attachment_upload_directory(), &bytes)?;
        sdk_void!(draft::attachments::AttachmentListAddResult, block_on(list.add(staged.0.to_string_lossy().into(), Some(name))))
            .map_err(|_| "attachment_failed")?;
        self.composer_value()
    }
    pub fn remove_attachment(&mut self, token: u64, attachment: u64) -> Result<Value, &'static str> {
        let draft = self.editable_draft(token)?;
        if !self.draft_attachments()?.iter().any(|a| a["id"].as_u64() == Some(attachment)) { return Err("invalid_selection"); }
        sdk_void!(draft::attachments::AttachmentListRemoveResult, block_on(draft.attachment_list().remove(Id::from(attachment))))
            .map_err(|_| "attachment_failed")?;
        self.composer_value()
    }
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn transfer_bounds_framing_expiry_and_single_use() {
        assert_eq!(unhex(&hex(b"SYNTHETIC\0\xff")).unwrap(), b"SYNTHETIC\0\xff");
        for invalid in ["0", "gg", "FF", "\u{00e9}"] { assert!(unhex(invalid).is_err()); }
        assert!(unhex(&"aa".repeat(CHUNK+1)).is_err());
        let mut t = Transfers::default(); let token = t.start(Kind::Upload { draft:1,name:"test.txt".into(),size:0,bytes:vec![] });
        assert!(t.take(token+1).is_err()); assert!(t.take(token).is_err());
        let token = t.start(Kind::Upload { draft:1,name:"test.txt".into(),size:0,bytes:vec![] });
        t.current.as_mut().unwrap().started = Instant::now() - Duration::from_secs(121);
        assert!(t.take(token).is_err());
    }
    #[test] fn filenames_cannot_select_paths_or_inject_display_controls() {
        assert_eq!(filename("../../x\\y:test\n.txt"),"xytest.txt");
        assert_eq!(filename("..."),"attachment");
        assert_eq!(filename("report\u{202e}fdp.exe"),"reportfdp.exe");
        assert!(filename(&"👩".repeat(500)).len() <= 240);
    }
    #[test] fn native_file_protocol_never_accepts_a_path_or_unknown_target_scope() {
        let packet = json!({"schema":1,"id":1,"command":{"method":"upload_start","token":3,"name":"Synthetic.txt","size":4}});
        assert!(serde_json::from_value::<Request>(packet.clone()).is_ok());
        let mut path = packet; path["command"]["path"] = json!("/private/data");
        assert!(serde_json::from_value::<Request>(path).is_err());
        let download = json!({"schema":1,"id":1,"command":{"method":"attachment_download","folder":1,"item":11,"attachment":21,"destination":"/tmp/arbitrary"}});
        assert!(serde_json::from_value::<Request>(download).is_err());
    }
    #[test] fn staging_is_private_and_removed_after_use() {
        let mut random = [0u8;16]; SecRandom::default().copy_bytes(&mut random).unwrap();
        let root = std::env::temp_dir().join(format!("protonx-test-{}",hex(&random))); std::fs::create_dir(&root).unwrap();
        let path;
        { let file = stage(root.to_str().unwrap(),b"SYNTHETIC file").unwrap(); path = file.0.clone();
          use std::os::unix::fs::PermissionsExt;
          assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,0o600);
          assert_eq!(std::fs::read(&path).unwrap(), b"SYNTHETIC file"); }
        assert!(!path.exists()); std::fs::remove_dir(root).unwrap();
    }
}
