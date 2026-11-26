package argocd

import (
	"crypto/sha1"
	"fmt"
)

// gitBlobSHA computes the git blob sha1 for content, matching git hash-object.
func gitBlobSHA(content []byte) string {
	h := sha1.New()
	fmt.Fprintf(h, "blob %d\x00", len(content))
	h.Write(content)
	return fmt.Sprintf("%x", h.Sum(nil))
}
