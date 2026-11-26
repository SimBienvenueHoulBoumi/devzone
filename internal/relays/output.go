package relays

import (
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"strings"
)

const (
	appResponds  = "application responds"
	appNone      = "no application"
	jsonResponds = "application répond"
	jsonNone     = "aucune application"
)

// jsonRelay keeps the key order of the JSON relay contract.
type jsonRelay struct {
	Port        int    `json:"port"`
	Active      bool   `json:"active"`
	Application string `json:"application"`
	Auto        bool   `json:"auto"`
}

// List writes the relays of the state, sorted, with their activity and the
// application behind them, as ports.sh list did.
func (e *Env) List() error {
	ports := PortList(e.State)
	if len(ports) == 0 {
		fmt.Fprintln(e.Out, "no relay")
		return nil
	}
	for _, n := range ports {
		mark := "○ stopped"
		if e.Active(n) {
			mark = "● active"
		}
		app := appNone
		if e.responds(n) {
			app = appResponds
		}
		fmt.Fprintf(e.Out, "  %-5s %s  %s\n", strconv.Itoa(n), mark, app)
	}
	return nil
}

// Summary writes the one-line recap of the relays of the state, as ports.sh
// resume did for the devzone status.
func (e *Env) Summary() error {
	ports := PortList(e.State)
	if len(ports) == 0 {
		fmt.Fprintln(e.Out, "none")
		return nil
	}
	parts := make([]string, 0, len(ports))
	for _, n := range ports {
		mark := "○"
		if e.Active(n) {
			mark = "●"
		}
		parts = append(parts, strconv.Itoa(n)+" "+mark)
	}
	fmt.Fprintln(e.Out, strings.Join(parts, ", "))
	return nil
}

// JSON writes the machine-readable array of relays read by devzone status
// --json, with the French application values of the contract.
func (e *Env) JSON() error {
	items := make([]jsonRelay, 0)
	for _, n := range PortList(e.State) {
		item := jsonRelay{Port: n, Application: jsonNone}
		if e.Active(n) {
			item.Active = true
		}
		if e.responds(n) {
			item.Application = jsonResponds
		}
		items = append(items, item)
	}
	data, err := json.Marshal(items)
	if err != nil {
		return err
	}
	_, err = io.WriteString(e.Out, string(data)+"\n")
	return err
}
