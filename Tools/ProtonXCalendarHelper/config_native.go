// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
// Session model adapted from proton-cal (Unlicense); all storage is injected.
package config

import (
	"encoding/json"
	"errors"
	"sync"
)

const DefaultBaseURL = "https://mail-api.proton.me"
const EnvConfigDir = "PROTON_CAL_CONFIG_DIR" // Test compatibility; never read by this adapter.
type Config struct{ Username, Timezone, BaseURL string }

func (c Config) EffectiveBaseURL() string {
	if c.BaseURL != "" {
		return c.BaseURL
	}
	return DefaultBaseURL
}
func (c Config) EffectiveTimezone() string {
	if c.Timezone != "" {
		return c.Timezone
	}
	return "UTC"
}
func Load() (Config, error)                { return Config{}, nil }
func Save(Config) error                    { return ErrStorage }
func Dir() (string, error)                 { return "", ErrStorage }
func writeFileAtomic(string, []byte) error { return ErrStorage }

type Session struct {
	UID           string `json:"uid"`
	AccessToken   string `json:"access_token"`
	RefreshToken  string `json:"refresh_token"`
	SaltedKeyPass []byte `json:"salted_key_pass,omitempty"`
}

func (s Session) Valid() bool { return s.UID != "" && s.AccessToken != "" && s.RefreshToken != "" }

var ErrNoSession = errors.New("no Calendar session")
var ErrStorage = errors.New("Calendar session storage unavailable")

type Backend interface {
	Read() ([]byte, error)
	Write([]byte) error
	Delete() error
}

var storage struct {
	sync.Mutex
	backend Backend
}

// SetBackend is called once by the native helper before authentication. Tests
// inject memory storage; no upstream test can accidentally touch Keychain.
func SetBackend(b Backend) { storage.Lock(); defer storage.Unlock(); storage.backend = b }

type SessionStore struct{}

func NewSessionStore() (*SessionStore, error) { return &SessionStore{}, nil }
func loadLocked() (Session, error) {
	if storage.backend == nil {
		return Session{}, ErrStorage
	}
	data, err := storage.backend.Read()
	if err != nil {
		return Session{}, err
	}
	defer clear(data)
	if len(data) > 32768 {
		return Session{}, ErrStorage
	}
	var s Session
	if json.Unmarshal(data, &s) != nil || !s.Valid() {
		return Session{}, ErrStorage
	}
	return s, nil
}
func saveLocked(s Session) error {
	if storage.backend == nil || !s.Valid() {
		return ErrStorage
	}
	data, err := json.Marshal(s)
	if err != nil || len(data) > 32768 {
		return ErrStorage
	}
	defer clear(data)
	return storage.backend.Write(data)
}
func (*SessionStore) Load() (Session, error) {
	storage.Lock()
	defer storage.Unlock()
	return loadLocked()
}
func (*SessionStore) Save(s Session) error {
	storage.Lock()
	defer storage.Unlock()
	return saveLocked(s)
}
func (*SessionStore) UpdateTokens(uid, access, refresh string) error {
	storage.Lock()
	defer storage.Unlock()
	s, err := loadLocked()
	if err != nil {
		return err
	}
	s.UID = uid
	s.AccessToken = access
	s.RefreshToken = refresh
	return saveLocked(s)
}
func (*SessionStore) Clear() error {
	storage.Lock()
	defer storage.Unlock()
	if storage.backend == nil {
		return ErrStorage
	}
	return storage.backend.Delete()
}
func lock(string) (func(), error) { return nil, ErrStorage }
