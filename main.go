// Companion runs the bundled interface locally and uses the shared Supabase backend.
package main
import (
 "embed"
 "io/fs"
 "fmt"
 "log"
 "net"
 "net/http"
 "os/exec"
 "time"
)
//go:embed docs
var content embed.FS
func main(){
 const url="http://127.0.0.1:8765/"
 listener,err:=net.Listen("tcp","127.0.0.1:8765")
 if err!=nil {fmt.Println("Не удалось открыть порт 8765. Закройте другую копию приложения.");fmt.Scanln();return}
 assets,_:=fs.Sub(content,"docs")
 fmt.Println("Companion Messenger\n"+url+"\nЛичные чаты работают через общую базу в интернете.\nЗакройте это окно, чтобы остановить приложение.")
 _=exec.Command("rundll32","url.dll,FileProtocolHandler",url).Start()
 server:=http.Server{Handler:http.FileServer(http.FS(assets)),ReadHeaderTimeout:5*time.Second,IdleTimeout:60*time.Second}
 log.Fatal(server.Serve(listener))
}
