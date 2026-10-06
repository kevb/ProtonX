// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// Opt-in candidate: legacy profiles are refused, never automatically rewritten.
use protonx_mail_storage::{
    ProfileGuard, StorageError, configure_database_key, database_files, validate_encrypted,
};
use security_framework::passwords::{get_generic_password, set_generic_password};
use security_framework::random::SecRandom;
use std::path::Path;
use zeroize::Zeroizing;

const SERVICE: &str = "org.kevb.ProtonX.Mail.Storage";
const ACCOUNT: &str = "database-v1";

pub fn prepare(root: &Path) -> Result<ProfileGuard, &'static str> {
    let guard = ProfileGuard::acquire(root).map_err(|_| "storage_unavailable")?;
    guard.check_startup(true).map_err(|error| match error {
        StorageError::UpgradeRequired => "storage_upgrade_required",
        StorageError::MigrationPending => "storage_migration_pending",
        _ => "storage_unavailable",
    })?;
    let databases = database_files(root).map_err(|_| "storage_unavailable")?;
    let key = match get_generic_password(SERVICE, ACCOUNT) {
        Ok(value) => {
            let value = Zeroizing::new(value);
            let bytes: [u8; 32] = value
                .as_slice()
                .try_into()
                .map_err(|_| "storage_unavailable")?;
            Zeroizing::new(bytes)
        }
        Err(error) if error.code() == -25300 && databases.is_empty() => {
            let mut bytes = Zeroizing::new([0_u8; 32]);
            SecRandom::default()
                .copy_bytes(bytes.as_mut_slice())
                .map_err(|_| "storage_unavailable")?;
            set_generic_password(SERVICE, ACCOUNT, bytes.as_slice())
                .map_err(|_| "storage_unavailable")?;
            bytes
        }
        Err(error) if error.code() == -25300 => return Err("storage_key_missing"),
        Err(_) => return Err("storage_unavailable"),
    };
    for path in &databases {
        validate_encrypted(path, &key).map_err(|_| "storage_unavailable")?;
    }
    configure_database_key(*key).map_err(|_| "storage_unavailable")?;
    Ok(guard)
}
