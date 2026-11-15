// Companion launches the hosted web application in the default browser.
package main
import "os/exec"
func main(){ _ = exec.Command("rundll32", "url.dll,FileProtocolHandler", "https://ipoteca22848.github.io/tg/").Start() }
