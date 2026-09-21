package codes

import (
	"strings"
	"testing"
	"time"
)

func TestGenerateShape(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 1000; i++ {
		c, err := Generate()
		if err != nil {
			t.Fatal(err)
		}
		if len(c) != Length {
			t.Fatalf("len %d", len(c))
		}
		for _, ch := range c {
			if !strings.ContainsRune(Alphabet, ch) {
				t.Fatalf("bad char %q in %s", ch, c)
			}
		}
		if seen[c] {
			t.Fatalf("duplicate %s", c)
		}
		seen[c] = true
	}
}

func TestNormalize(t *testing.T) {
	cases := map[string]string{
		"3K7QW-P9X2M":  "3K7QWP9X2M",
		"3k7qw p9x2m":  "3K7QWP9X2M",
		"3k7qwp9x2m":   "3K7QWP9X2M",
		"OIL1-234567":  "0111234567",
		" 3K7QW-P9X2M": "3K7QWP9X2M",
	}
	for in, want := range cases {
		got, err := Normalize(in)
		if err != nil || got != want {
			t.Errorf("Normalize(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	bad := []string{"", "3K7QW", "3K7QWP9X2MZ", "3K7QW-P9X2U", "3K7QW-P9X2*", "3K7QW-P9X2é"}
	for _, in := range bad {
		if _, err := Normalize(in); err == nil {
			t.Errorf("Normalize(%q) should fail", in)
		}
	}
}

func TestFormat(t *testing.T) {
	if got := Format("3K7QWP9X2M"); got != "3K7QW-P9X2M" {
		t.Fatal(got)
	}
}

func TestRegistryLifecycle(t *testing.T) {
	r := NewRegistry()
	now := time.Now()
	e, err := r.Add("s1", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	got, err := r.Lookup(Format(strings.ToLower(e.Code)), now)
	if err != nil || got.ID != "s1" {
		t.Fatalf("lookup: %v %v", got, err)
	}
	if _, err := r.Lookup(e.Code, now.Add(2*time.Minute)); err != ErrExpired {
		t.Fatalf("want expired, got %v", err)
	}
	// Wrong key with the same prefix must not match.
	prefix, key := Split(e.Code)
	altKey := []byte(key)
	altKey[0] = Alphabet[(strings.IndexByte(Alphabet, altKey[0])+1)%32]
	if _, err := r.Lookup(prefix+string(altKey), now); err != ErrNotFound {
		t.Fatalf("want not found, got %v", err)
	}
	if _, err := r.Add("s1", now.Add(time.Minute)); err == nil {
		t.Fatal("duplicate id accepted")
	}
	if !r.Remove("s1") || r.Remove("s1") {
		t.Fatal("remove semantics")
	}
	if _, err := r.Lookup(e.Code, now); err != ErrNotFound {
		t.Fatalf("want not found after remove, got %v", err)
	}
}

func TestRegistrySweep(t *testing.T) {
	r := NewRegistry()
	now := time.Now()
	r.Add("a", now.Add(-time.Second))
	r.Add("b", now.Add(time.Hour))
	ids := r.Sweep(now)
	if len(ids) != 1 || ids[0] != "a" || r.Len() != 1 {
		t.Fatalf("sweep: %v len=%d", ids, r.Len())
	}
}

func TestLogPrefix(t *testing.T) {
	if LogPrefix("3K7QWP9X2M") != "3K7Q******" {
		t.Fatal(LogPrefix("3K7QWP9X2M"))
	}
}
