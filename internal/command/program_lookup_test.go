package command

import "errors"

// programLookPath finds only the named programs. It never reads the process
// PATH, so the same test passes on every host, with or without kubectl or helm.
func programLookPath(names ...string) func(string) (string, error) {
	return func(name string) (string, error) {
		for _, n := range names {
			if n == name {
				return name, nil
			}
		}
		return "", errors.New(name + " not found")
	}
}
