package web

import "embed"

// Assets contains the complete dependency-free browser viewer. Embedding the
// page and every module in the Go binary prevents the Docker image, signaling
// protocol, and viewer implementation from drifting across deployments.
//
//go:embed viewer.html assets
var Assets embed.FS
