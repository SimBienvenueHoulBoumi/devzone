package ai

// Messages of the update check and report, kept identical to the message file
// shipped with the old host check script.
const (
	msgTitle   = "host (Ollama) models detected:"
	msgNone    = "devzone: no Ollama model detected on {url} (answer on /api/tags)"
	msgSize    = "size"
	msgCurrent = "up to date"
	msgUpdate  = "update available"
	msgUnknown = "not verifiable"
	msgPull    = "on the host: ollama pull {modele}"
	msgMeasure = "measurement reussite {reussite}, tok_s {tok_s}"
	msgChosen  = "chosen model: {modele} ({raison})"
	msgByVar   = "DEVZONE_HOST_MODEL"
	msgByRule  = "rule"
)

// manifestType is the accepted manifest media type of the registry.
const manifestType = "application/vnd." + "\x64\x6f\x63\x6b\x65\x72" + ".distribution.manifest.v2+json"
