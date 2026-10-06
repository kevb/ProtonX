// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: AGPL-3.0-only
// This module has no database/crypto dependency; both helper variants use it.
use std::fs::{self, File, OpenOptions};
use std::io::Read;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
const HEADER: &[u8] = b"SQLite format 3\0";
pub const MIGRATION_DIRECTORY: &str = ".storage-migration";
pub const FORMAT_FILE: &str = ".storage-format";
pub const ENCRYPTED_FORMAT: &[u8] = b"protonx-mail-sqlcipher-v1\n";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StorageError {
    Unavailable,
    Busy,
    UpgradeRequired,
    MissingKey,
    InvalidProfile,
    MigrationPending,
    EncryptedProfile,
    SourceChanged,
    RecoveryRequired,
}

pub struct ProfileGuard {
    file: File,
    root: PathBuf,
}
impl ProfileGuard {
    pub fn acquire(root: &Path) -> Result<Self, StorageError> {
        fs::create_dir_all(root).map_err(|_| StorageError::Unavailable)?;
        if fs::symlink_metadata(root)
            .map_err(|_| StorageError::Unavailable)?
            .file_type()
            .is_symlink()
        {
            return Err(StorageError::InvalidProfile);
        }
        let lock_path = root.join(".storage.lock");
        if let Ok(metadata) = fs::symlink_metadata(&lock_path) {
            if !metadata.is_file() || metadata.nlink() != 1 {
                return Err(StorageError::InvalidProfile);
            }
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(lock_path)
            .map_err(|_| StorageError::Unavailable)?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(StorageError::Busy);
        }
        Ok(Self {
            file,
            root: root.to_owned(),
        })
    }
}
impl Drop for ProfileGuard {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

pub fn database_files(root: &Path) -> Result<Vec<PathBuf>, StorageError> {
    fn visit(path: &Path, output: &mut Vec<PathBuf>, depth: usize) -> Result<(), StorageError> {
        if depth > 12 {
            return Err(StorageError::InvalidProfile);
        }
        let metadata = match fs::symlink_metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(_) => return Err(StorageError::Unavailable),
        };
        if metadata.file_type().is_symlink() {
            return Err(StorageError::InvalidProfile);
        }
        if metadata.is_dir() {
            for child in fs::read_dir(path).map_err(|_| StorageError::Unavailable)? {
                visit(
                    &child.map_err(|_| StorageError::Unavailable)?.path(),
                    output,
                    depth + 1,
                )?;
            }
        } else if !metadata.is_file() {
            return Err(StorageError::InvalidProfile);
        } else if metadata.nlink() != 1 {
            return Err(StorageError::InvalidProfile);
        } else if path.extension().is_some_and(|s| s == "db" || s == "sqlite") {
            if output.len() >= 128 {
                return Err(StorageError::InvalidProfile);
            }
            output.push(path.to_owned());
        }
        Ok(())
    }
    let mut files = vec![];
    for name in ["sessions", "users"] {
        visit(&root.join(name), &mut files, 0)?;
    }
    files.sort();
    Ok(files)
}

pub fn is_plaintext(path: &Path) -> Result<bool, StorageError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| StorageError::Unavailable)?;
    if !metadata.is_file() || metadata.nlink() != 1 {
        return Err(StorageError::InvalidProfile);
    }
    let mut header = [0_u8; 16];
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|_| StorageError::Unavailable)?;
    file.read_exact(&mut header)
        .map_err(|_| StorageError::Unavailable)?;
    Ok(header == HEADER)
}

impl ProfileGuard {
    /// The guard must remain held until SDK connections/workers are closed.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Run before Keychain access or SDK initialization. Migration owns the entire
    /// profile while this directory exists, including after an interrupted export.
    pub fn check_startup(&self, encrypted: bool) -> Result<(), StorageError> {
        match fs::symlink_metadata(self.root.join(MIGRATION_DIRECTORY)) {
            Ok(_) => return Err(StorageError::MigrationPending),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(StorageError::Unavailable),
        }
        let format_path = self.root.join(FORMAT_FILE);
        match fs::symlink_metadata(&format_path) {
            Ok(metadata) => {
                if !metadata.is_file()
                    || metadata.nlink() != 1
                    || metadata.len() != ENCRYPTED_FORMAT.len() as u64
                {
                    return Err(StorageError::InvalidProfile);
                }
                let mut file = OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_NOFOLLOW)
                    .open(format_path)
                    .map_err(|_| StorageError::Unavailable)?;
                let mut value = Vec::new();
                file.read_to_end(&mut value)
                    .map_err(|_| StorageError::Unavailable)?;
                if value != ENCRYPTED_FORMAT {
                    return Err(StorageError::InvalidProfile);
                }
                if !encrypted {
                    return Err(StorageError::EncryptedProfile);
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => return Err(StorageError::Unavailable),
        }
        // Also recognize encrypted databases created before the format marker.
        for path in database_files(&self.root)? {
            let plaintext = is_plaintext(&path)?;
            if !encrypted && !plaintext {
                return Err(StorageError::EncryptedProfile);
            }
            if encrypted && plaintext {
                return Err(StorageError::UpgradeRequired);
            }
        }
        Ok(())
    }
}
