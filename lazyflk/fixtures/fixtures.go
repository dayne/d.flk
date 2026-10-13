// Package fixtures embeds real flk output from the reference host (see
// README.md) so --demo and the tests run without flk.
package fixtures

import "embed"

//go:embed *.json *.txt
var FS embed.FS
