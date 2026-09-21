// Package legal supplies notices alongside standalone server binaries.
package legal

import _ "embed"

// Notices contains copyright/license text from the locked Go dependencies.
//
//go:embed NOTICE.txt
var Notices string
