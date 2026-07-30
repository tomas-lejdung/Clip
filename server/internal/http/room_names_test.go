package httpapi

import (
	"strings"
	"testing"

	"github.com/tomas-lejdung/Clip/server/internal/protocol"
)

func TestCryptographicRoomNamesUseThePublicMemorableFormat(t *testing.T) {
	t.Parallel()
	for range 128 {
		name, err := cryptographicRoomName()
		if err != nil {
			t.Fatal(err)
		}
		normalized, err := protocol.NormalizeRoomName(name)
		if err != nil || normalized != name {
			t.Fatalf("cryptographicRoomName() = %q, normalization = %q, %v", name, normalized, err)
		}
		parts := strings.Split(name, "-")
		if len(parts) != 3 || len(parts[2]) != 3 {
			t.Fatalf("cryptographicRoomName() = %q; want ADJECTIVE-NOUN-###", name)
		}
	}
}
