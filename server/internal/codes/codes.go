// Package codes implements CrossTransfer take-codes: 10-character Crockford
// Base32 strings carrying 50 bits of CSPRNG entropy, split into a 4-character
// routing prefix and a 6-character key. It also provides the in-memory share
// registry that maps codes to share IDs with prefix indexing and constant-time
// key comparison.
package codes

import (
	"crypto/rand"
	"crypto/subtle"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"
)

// Alphabet is the Crockford Base32 alphabet (no I, L, O, U).
const Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

const (
	// Length is the number of symbols in a take-code.
	Length = 10
	// PrefixLen is the number of leading symbols used as the routing prefix.
	PrefixLen = 4
	// KeyLen is the number of trailing symbols used as the secret key.
	KeyLen = Length - PrefixLen
)

var (
	ErrInvalidCode = errors.New("invalid take-code")
	ErrNotFound    = errors.New("code not found")
	ErrExpired     = errors.New("code expired")
)

var alphabetIndex = func() [256]int8 {
	var t [256]int8
	for i := range t {
		t[i] = -1
	}
	for i := 0; i < len(Alphabet); i++ {
		t[Alphabet[i]] = int8(i)
	}
	// Crockford decoding aliases for confusable characters.
	t['O'] = t['0']
	t['I'] = t['1']
	t['L'] = t['1']
	return t
}()

// Generate returns a fresh random take-code (canonical form, no separator).
func Generate() (string, error) {
	var buf [Length]byte
	if _, err := rand.Read(buf[:]); err != nil {
		return "", err
	}
	// Each byte gives 8 bits; we use the low 5 bits. rand.Read is uniform, so
	// masking keeps the distribution uniform over 32 symbols.
	out := make([]byte, Length)
	for i := range buf {
		out[i] = Alphabet[buf[i]&0x1f]
	}
	return string(out), nil
}

// Normalize canonicalizes user input: strips separators and whitespace,
// upper-cases, maps O→0 and I/L→1, and validates length and alphabet.
func Normalize(s string) (string, error) {
	out := make([]byte, 0, Length)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '-' || c == ' ' || c == '\t' || c == '_':
			continue
		case c >= 'a' && c <= 'z':
			c -= 'a' - 'A'
		}
		if c >= 0x80 {
			return "", ErrInvalidCode
		}
		idx := alphabetIndex[c]
		if idx < 0 {
			return "", ErrInvalidCode
		}
		if len(out) >= Length {
			return "", ErrInvalidCode
		}
		out = append(out, Alphabet[idx])
	}
	if len(out) != Length {
		return "", ErrInvalidCode
	}
	return string(out), nil
}

// Format renders a canonical code for display as XXXXX-XXXXX.
func Format(code string) string {
	if len(code) != Length {
		return code
	}
	return code[:5] + "-" + code[5:]
}

// Split returns the prefix and key parts of a canonical code.
func Split(code string) (prefix, key string) {
	return code[:PrefixLen], code[PrefixLen:]
}

// Entry is a registered code.
type Entry struct {
	ID        string // share ID chosen by the caller
	Code      string // canonical code
	ExpiresAt time.Time
}

// Registry is a thread-safe in-memory code table with a prefix index.
type Registry struct {
	mu       sync.Mutex
	byPrefix map[string][]*Entry
	byID     map[string]*Entry
}

// NewRegistry creates an empty registry.
func NewRegistry() *Registry {
	return &Registry{
		byPrefix: make(map[string][]*Entry),
		byID:     make(map[string]*Entry),
	}
}

// Add allocates a unique code for id, valid until expiresAt.
func (r *Registry) Add(id string, expiresAt time.Time) (*Entry, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, dup := r.byID[id]; dup {
		return nil, fmt.Errorf("share %q already registered", id)
	}
	for attempt := 0; attempt < 16; attempt++ {
		code, err := Generate()
		if err != nil {
			return nil, err
		}
		prefix, _ := Split(code)
		if r.findLocked(prefix, code) != nil {
			continue
		}
		e := &Entry{ID: id, Code: code, ExpiresAt: expiresAt}
		r.byPrefix[prefix] = append(r.byPrefix[prefix], e)
		r.byID[id] = e
		return e, nil
	}
	return nil, errors.New("failed to allocate a unique code")
}

// findLocked scans the prefix bucket comparing keys in constant time. It
// always walks the whole bucket so timing does not reveal the match position.
func (r *Registry) findLocked(prefix, code string) *Entry {
	var found *Entry
	key := []byte(code[PrefixLen:])
	for _, e := range r.byPrefix[prefix] {
		if subtle.ConstantTimeCompare([]byte(e.Code[PrefixLen:]), key) == 1 {
			found = e
		}
	}
	return found
}

// Lookup resolves a code (any accepted input form). It returns ErrExpired when
// the entry exists but its TTL has elapsed.
func (r *Registry) Lookup(input string, now time.Time) (*Entry, error) {
	code, err := Normalize(input)
	if err != nil {
		return nil, ErrNotFound
	}
	prefix, _ := Split(code)
	r.mu.Lock()
	defer r.mu.Unlock()
	e := r.findLocked(prefix, code)
	if e == nil {
		return nil, ErrNotFound
	}
	if !now.Before(e.ExpiresAt) {
		return nil, ErrExpired
	}
	return e, nil
}

// Remove drops the code registered for id. It returns false if absent.
func (r *Registry) Remove(id string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.byID[id]
	if !ok {
		return false
	}
	delete(r.byID, id)
	prefix, _ := Split(e.Code)
	bucket := r.byPrefix[prefix]
	for i, x := range bucket {
		if x == e {
			bucket = append(bucket[:i], bucket[i+1:]...)
			break
		}
	}
	if len(bucket) == 0 {
		delete(r.byPrefix, prefix)
	} else {
		r.byPrefix[prefix] = bucket
	}
	return true
}

// Sweep removes every entry expired at now and returns their IDs.
func (r *Registry) Sweep(now time.Time) []string {
	r.mu.Lock()
	var ids []string
	for id, e := range r.byID {
		if !now.Before(e.ExpiresAt) {
			ids = append(ids, id)
		}
	}
	r.mu.Unlock()
	for _, id := range ids {
		r.Remove(id)
	}
	return ids
}

// Len returns the number of registered codes.
func (r *Registry) Len() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.byID)
}

// LogPrefix returns the prefix portion for logging (never log full codes).
func LogPrefix(code string) string {
	if len(code) < PrefixLen {
		return strings.Repeat("?", PrefixLen)
	}
	return code[:PrefixLen] + "******"
}
