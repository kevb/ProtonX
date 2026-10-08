// Copyright (c) 2026 ProtonX contributors. SPDX-License-Identifier: GPL-3.0-or-later
// Inserted into upstream domain test packages only. No OS credential access.
package PACKAGE

import (
	"github.com/cheeseandcereal/proton-cal/pkg/config"
	"os"
	"sync"
	"testing"
)

type nativeTestStorage struct {
	sync.Mutex
	data map[string][]byte
}

func (b *nativeTestStorage) Read() ([]byte, error) {
	b.Lock()
	defer b.Unlock()
	v := b.data[os.Getenv(config.EnvConfigDir)]
	if len(v) == 0 {
		return nil, config.ErrNoSession
	}
	return append([]byte(nil), v...), nil
}
func (b *nativeTestStorage) Write(v []byte) error {
	b.Lock()
	defer b.Unlock()
	b.data[os.Getenv(config.EnvConfigDir)] = append([]byte(nil), v...)
	return nil
}
func (b *nativeTestStorage) Delete() error {
	b.Lock()
	defer b.Unlock()
	delete(b.data, os.Getenv(config.EnvConfigDir))
	return nil
}
func TestMain(m *testing.M) {
	config.SetBackend(&nativeTestStorage{data: make(map[string][]byte)})
	os.Exit(m.Run())
}
