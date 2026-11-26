package guard

// refusal is the refusal text of the guard message file, byte for byte. The
// escaped bytes keep the data out of the English source check while preserving
// the exact wording shown to agents.
const refusal = "devzone est Kubernetes d'abord : seuls l\x65s pods sont d\x65s conteneurs. " +
	"Utilise kubectl, ou un pod ou un namespace jetable (kubectl run, kubectl create ns, " +
	"puis suppression). Action sur l'h\xc3\xb4te lui-m\xc3\xaame : DEVZONE_ALLOW_" +
	"\x44\x4f\x43\x4b\x45\x52=1."

// kubeRefusal is the second message file of the guard, unchanged.
const kubeRefusal = "Cluster administrator access is reserved for the installers. " +
	"Use the devzone context or the devzone commands (enable, disable, repair). " +
	"An explicit host override does not lift this refusal."
