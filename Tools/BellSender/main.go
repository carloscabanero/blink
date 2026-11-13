// Run from the blinksh/bell module: go run /path/to/blink/Tools/BellSender/main.go ...
// Reads only the copied SEND.READ capability, never an app journal or MANAGE key.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/blinksh/bell/bellproto"
)

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func main() {
	relay := flag.String("relay", "https://bell.blink.sh", "Relay origin")
	bid := flag.String("bell-id", "", "32-hex Bell ID, required for sending")
	ask := flag.Bool("ask", false, "send a confirm Ask")
	lookup := flag.String("lookup", "", "look up Ask ID and verify returned verdict MAC")
	loud := flag.Bool("loud", true, "request alert (false sends state only)")
	progress := flag.Int("progress", 73, "state progress 0..100")
	ttl := flag.Int("ttl", 120, "Ask lifetime in seconds")
	flag.Parse()
	parts := strings.Split(strings.TrimSpace(os.Getenv("BLINK_BELL")), ".")
	if len(parts) != 2 {
		must(fmt.Errorf("BLINK_BELL must be the copied token.content_secret"))
	}
	_, err := bellproto.ParseToken(parts[0])
	must(err)
	secret, err := base64.StdEncoding.DecodeString(parts[1])
	must(err)
	if len(secret) != 32 {
		must(fmt.Errorf("invalid content secret"))
	}
	client := &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	origin := strings.TrimRight(*relay, "/")
	if !strings.HasPrefix(origin, "https://") {
		must(fmt.Errorf("use an HTTPS Relay origin"))
	}
	method, path := "GET", "/asks/"+*lookup
	var body []byte
	if *lookup == "" {
		id, e := bellproto.ParseBellID(*bid)
		must(e)
		var mid [16]byte
		_, e = rand.Read(mid[:])
		must(e)
		ts := time.Now().Unix()
		plaintext, e := json.Marshal(bellproto.Sealed{Title: "Carlos Bell test", Body: "Encrypted notification. No command is executed.", AskPrompt: "Approve this test?"})
		must(e)
		ct, e := bellproto.SealRandom(secret, plaintext, bellproto.AAD(id, mid, ts))
		must(e)
		m := bellproto.Message{Enc: true, CT: ct, ID: base64.RawURLEncoding.EncodeToString(mid[:]), TS: ts, Ring: loud, State: "ok", Progress: progress}
		if *ask {
			m.Ask = &bellproto.Ask{Kind: "confirm", TTL: *ttl}
		}
		must(m.Validate())
		body, e = json.Marshal(m)
		must(e)
		fmt.Println("Message / Ask ID:", m.ID)
		method, path = "POST", "/r"
	}
	req, err := http.NewRequest(method, origin+path, bytes.NewReader(body))
	must(err)
	req.Header.Set("Authorization", "Bearer "+parts[0])
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	must(err)
	defer resp.Body.Close()
	out, err := io.ReadAll(io.LimitReader(resp.Body, 65536))
	must(err)
	fmt.Printf("HTTP %d: %s\n", resp.StatusCode, out)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		os.Exit(1)
	}
	if *lookup != "" {
		var result struct{ Verdict, MAC string }
		must(json.Unmarshal(out, &result))
		if result.Verdict == "" {
			fmt.Println("No verdict yet (pending or expired); this is not approval.")
			return
		}
		mac, e := base64.RawURLEncoding.DecodeString(result.MAC)
		must(e)
		if !bellproto.VerifyVerdictMAC(secret, *lookup, result.Verdict, mac) {
			must(fmt.Errorf("INVALID verdict MAC"))
		}
		fmt.Println("Verified sender verdict MAC:", result.Verdict)
	}
}
