package brokerrpc

import "time"

// The independent authorization receiver validates deadlines against its own
// clock with a strict five-minute cap. Leave a small margin; never extend a
// session or the receiver's cap to compensate for clock/transport differences.
const PolicyLeaseDuration = 5*time.Minute - 5*time.Second
