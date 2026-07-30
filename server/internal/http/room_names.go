package httpapi

import (
	"crypto/rand"
	"fmt"
	"math/big"
)

const maximumRoomAllocationAttempts = 32

var roomAdjectives = [...]string{
	"AMBER", "BRAVE", "BRIGHT", "CALM", "CLEAR", "CORAL", "CRISP", "EAGER",
	"EMBER", "FAIR", "FROSTY", "GENTLE", "GOLDEN", "HAPPY", "JADE", "KEEN",
	"LIVELY", "LUCID", "MELLOW", "MINT", "NIMBLE", "NOBLE", "PLUM", "QUICK",
	"QUIET", "RAPID", "SILVER", "SOLAR", "SWIFT", "TIDY", "VIVID", "WARM",
}

var roomNouns = [...]string{
	"BADGER", "BEAR", "BISON", "CEDAR", "COMET", "CRANE", "DOLPHIN", "FALCON",
	"FERN", "FINCH", "FOX", "GECKO", "HERON", "IBIS", "KOALA", "LARK",
	"LYNX", "MAPLE", "MARTEN", "MOON", "ORCA", "OTTER", "OWL", "PANDA",
	"PINE", "RAVEN", "ROBIN", "SEAL", "SPARROW", "TIGER", "WILLOW", "WREN",
}

func cryptographicRoomName() (string, error) {
	adjective, err := cryptographicIndex(len(roomAdjectives))
	if err != nil {
		return "", err
	}
	noun, err := cryptographicIndex(len(roomNouns))
	if err != nil {
		return "", err
	}
	number, err := cryptographicIndex(1_000)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%s-%s-%03d", roomAdjectives[adjective], roomNouns[noun], number), nil
}

func cryptographicIndex(upperBound int) (int, error) {
	value, err := rand.Int(rand.Reader, big.NewInt(int64(upperBound)))
	if err != nil {
		return 0, err
	}
	return int(value.Int64()), nil
}
