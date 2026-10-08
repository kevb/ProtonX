// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Contact sync, card decryption and interpretation stay in Proton's pinned Mail SDK.
use super::*;
use mail_uniffi::core::datatypes::ContactItemType;
use mail_uniffi::core::datatypes::contact_details::{ContactField, ContactDate, VCardUrlValue};
use std::collections::HashSet;

const MAX_ENTRIES: usize = 5000;
const MAX_BYTES: usize = 4 * 1024 * 1024;
fn bounded(value: &Value, limit: usize) -> Result<(), &'static str> {
    if serde_json::to_vec(value).map_err(|_| "contacts_failed")?.len() > limit {
        return Err("contacts_too_large");
    }
    Ok(())
}
fn require_disclosed(ids: &HashSet<u64>, id: u64) -> Result<(), &'static str> {
    if id == 0 || !ids.contains(&id) { Err("invalid_selection") } else { Ok(()) }
}
fn date_text(date: ContactDate) -> String {
    match date {
        ContactDate::String(text) => text,
        ContactDate::Date(date) => [date.year.map(|v| format!("{v:04}")), date.month.map(|v| format!("{v:02}")), date.day.map(|v| format!("{v:02}"))]
            .into_iter().map(|v| v.unwrap_or_else(|| "—".into())).collect::<Vec<_>>().join("-"),
    }
}
impl Backend {
    pub(crate) fn contacts(&mut self) -> Result<Value, &'static str> {
        // Never retain a previous disclosure scope after a failed refresh.
        self.contact_ids.clear();
        let user = self.user.clone().ok_or("invalid_state")?;
        let groups = sdk_result!(mail_uniffi::mail::contacts::ContactListResult,
            block_on(mail_uniffi::mail::contacts::contact_list(user)))
            .map_err(|e| action_failure(e, "contacts_failed"))?;
        let mut entries = Vec::new();
        let mut ids = HashSet::new();
        for group in groups {
            for item in group.items {
                if entries.len() >= MAX_ENTRIES { return Err("contacts_too_large"); }
                let entry = match item {
                    ContactItemType::Contact(c) => {
                        ids.insert(c.id.as_u64());
                        json!({"localID":c.id.as_u64(),"kind":"contact","name":c.name,"emails":c.emails.iter().map(|e|json!({"contactID":e.contact_id.as_u64(),"name":e.name,"email":e.email})).collect::<Vec<_>>()})
                    }
                    ContactItemType::Group(g) => json!({"localID":g.id.as_u64(),"kind":"group","name":g.name,"emails":g.contact_emails.iter().map(|e|json!({"contactID":e.contact_id.as_u64(),"name":e.name,"email":e.email})).collect::<Vec<_>>()}),
                };
                entries.push(entry);
            }
        }
        let value = json!({"contacts":entries});
        bounded(&value, MAX_BYTES)?;
        self.contact_ids = ids;
        Ok(value)
    }
    pub(crate) fn contact_detail(&self, item: u64) -> Result<Value, &'static str> {
        require_disclosed(&self.contact_ids, item)?;
        let user = self.user.as_ref().ok_or("invalid_state")?;
        let card = sdk_result!(mail_uniffi::core::datatypes::contact_details::GetContactDetailsResult,
            block_on(mail_uniffi::core::datatypes::contact_details::get_contact_details(user, Id::from(item))))
            .map_err(|e| session_failure(e, "contact_detail_failed"))?;
        if card.id.as_u64() != item { return Err("invalid_selection"); }
        let mut fields = Vec::new();
        for field in card.fields {
            let (label, values) = match field {
                ContactField::Emails(v) => ("Email", v.into_iter().map(|e| e.email).collect()),
                ContactField::Telephones(v) => ("Phone", v.into_iter().map(|p| p.number).collect()),
                ContactField::Addresses(v) => ("Address", v.into_iter().map(|a| [a.street,a.city,a.region,a.postal_code,a.country].into_iter().flatten().collect::<Vec<_>>().join("\n")).collect()),
                ContactField::Birthday(v) => ("Birthday", vec![date_text(v)]),
                ContactField::Anniversary(v) => ("Anniversary", vec![date_text(v)]),
                ContactField::Organizations(v) => ("Organisation", v),
                ContactField::Titles(v) => ("Title", v),
                ContactField::Roles(v) => ("Role", v),
                ContactField::Notes(v) => ("Note", v),
                ContactField::Languages(v) => ("Language", v),
                ContactField::TimeZones(v) => ("Time zone", v),
                ContactField::Urls(v) => ("Website", v.into_iter().map(|v|match v.url { VCardUrlValue::Http(s)|VCardUrlValue::NotHttp(s)|VCardUrlValue::Text(s)=>s }).collect()),
                // Photo/logo URLs and member URIs are never fetched or opened.
                _ => continue,
            };
            for value in values { if !value.is_empty() { fields.push(json!({"label":label,"value":value})); } }
        }
        let result = json!({"contactDetail":{"localID":item,"fields":fields}});
        bounded(&result, 256 * 1024)?;
        Ok(result)
    }
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn details_require_current_disclosure_and_bounds() {
        let ids = HashSet::from([10]);
        assert!(require_disclosed(&ids,10).is_ok());
        assert!(require_disclosed(&ids,0).is_err());
        assert!(require_disclosed(&ids,11).is_err());
        assert!(require_disclosed(&HashSet::new(),10).is_err());
        assert!(bounded(&json!({"value":"synthetic"}),128).is_ok());
        assert_eq!(bounded(&json!({"value":"x".repeat(129)}),128),Err("contacts_too_large"));
    }
    #[test] fn closed_read_only_contact_commands() {
        for command in [json!({"method":"contacts"}),json!({"method":"contact_detail","item":10})] {
            assert!(serde_json::from_value::<Command>(command).is_ok());
        }
        for command in [json!({"method":"contacts","account":"other"}),json!({"method":"contact_detail","item":10,"remote_id":"other"}),json!({"method":"delete_contact","item":10})] {
            assert!(serde_json::from_value::<Command>(command).is_err());
        }
    }
}
