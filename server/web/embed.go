package web

import "embed"

// Assets contains the trusted, dependency-free browser viewer. The viewer is
// kept beside this declaration so the Go binary and Docker image cannot drift.
//
//go:embed viewer.html clip-viewer.js clip-protocol.js
var Assets embed.FS
