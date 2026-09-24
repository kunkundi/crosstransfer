// Package notification stores publisher announcements independently of transfer state.
package notification

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const Limit = 50

var ErrNotFound = errors.New("notification not found")

type Draft struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	Level string `json:"level"`
}

func (d *Draft) Validate() error {
	d.Title, d.Body = strings.TrimSpace(d.Title), strings.TrimSpace(d.Body)
	if !utf8.ValidString(d.Title) || !utf8.ValidString(d.Body) || len([]rune(d.Title)) < 1 || len([]rune(d.Title)) > 120 || len([]rune(d.Body)) < 1 || len([]rune(d.Body)) > 2000 {
		return errors.New("标题需为 1–120 字，正文需为 1–2000 字")
	}
	if d.Level != "info" && d.Level != "important" && d.Level != "maintenance" {
		return errors.New("请选择有效的通知级别")
	}
	return nil
}

type Item struct {
	Draft
	ID        string `json:"id"`
	CreatedAt int64  `json:"created_at"`
	RevokedAt int64  `json:"revoked_at,omitempty"`
}

type Store struct {
	mu    sync.Mutex
	path  string
	items []Item // newest first
	// Called under mu after persistence, preserving snapshot publication order.
	onChange func([]byte)
}

func Open(path string, onChange func([]byte)) (*Store, error) {
	s := &Store{path: path, items: []Item{}, onChange: onChange}
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return nil, err
	}
	if err == nil {
		if err := json.Unmarshal(data, &s.items); err != nil {
			return nil, fmt.Errorf("read notifications: %w", err)
		}
		if len(s.items) > Limit {
			return nil, errors.New("too many notification records")
		}
		seen := map[string]bool{}
		for _, item := range s.items {
			id, err := hex.DecodeString(item.ID)
			if err != nil || len(id) != 16 || seen[item.ID] || item.CreatedAt <= 0 || item.RevokedAt < 0 || item.Draft.Validate() != nil {
				return nil, errors.New("invalid notification record")
			}
			seen[item.ID] = true
		}
	}
	s.PublishSnapshot()
	return s, nil
}

func (s *Store) List() []Item {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Item{}, s.items...)
}

func (s *Store) Create(d Draft) (Item, error) {
	if err := d.Validate(); err != nil {
		return Item{}, err
	}
	id := make([]byte, 16)
	if _, err := rand.Read(id); err != nil {
		return Item{}, err
	}
	item := Item{Draft: d, ID: hex.EncodeToString(id), CreatedAt: time.Now().Unix()}
	s.mu.Lock()
	defer s.mu.Unlock()
	items := append([]Item{item}, s.items...)
	if len(items) > Limit {
		items = items[:Limit]
	}
	return item, s.Commit(items)
}

func (s *Store) Revoke(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	items := append([]Item{}, s.items...)
	for i := range items {
		if items[i].ID != id {
			continue
		}
		if items[i].RevokedAt != 0 {
			return nil
		}
		items[i].RevokedAt = time.Now().Unix()
		return s.Commit(items)
	}
	return ErrNotFound
}

// Commit leaves the previous state intact if saving fails. Caller holds mu.
func (s *Store) Commit(items []Item) error {
	data, err := json.MarshalIndent(items, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(s.path)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".notifications-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(f.Name(), s.path); err != nil {
		return err
	}
	s.items = items
	s.PublishSnapshot()
	return nil
}

// PublishSnapshot is called during startup or while holding mu.
func (s *Store) PublishSnapshot() {
	if s.onChange == nil {
		return
	}
	active := []Item{}
	for _, item := range s.items {
		if item.RevokedAt == 0 {
			active = append(active, item)
		}
	}
	data, _ := json.Marshal(struct {
		Type  string `json:"type"`
		Items []Item `json:"items"`
	}{"notifications", active})
	s.onChange(data)
}
