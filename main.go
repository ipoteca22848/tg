//go:build windows

// Companion is a desktop client. It opens no HTTP listener and starts no browser.
package main

import (
	"embed"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"unsafe"

	"github.com/jchv/go-webview2/pkg/edge"
	"golang.org/x/sys/windows"
)

//go:embed docs
var assets embed.FS
var user32 = windows.NewLazySystemDLL("user32.dll")
var kernel32 = windows.NewLazySystemDLL("kernel32.dll")
var browser *edge.Chromium
var window uintptr

type point struct{ X, Y int32 }
type message struct {
	Window         uintptr
	Message        uint32
	Wparam, Lparam uintptr
	Time           uint32
	Point          point
	Private        uint32
}
type windowClass struct {
	Size, Style                        uint32
	Proc                               uintptr
	ClassExtra, WindowExtra            int32
	Instance, Icon, Cursor, Background uintptr
	Menu, Class                        *uint16
	SmallIcon                          uintptr
}

func utf(s string) *uint16 { p, _ := windows.UTF16PtrFromString(s); return p }
func call(name string, args ...uintptr) uintptr {
	r, _, _ := user32.NewProc(name).Call(args...)
	return r
}
func showError(s string) {
	call("MessageBoxW", window, uintptr(unsafe.Pointer(utf(s))), uintptr(unsafe.Pointer(utf("Companion"))), 0x10)
}
func wndProc(hwnd uintptr, msg uint32, wp, lp uintptr) uintptr {
	switch msg {
	case 5:
		if browser != nil {
			if wp == 1 {
				browser.Eval("window.CompanionStopRecording&&window.CompanionStopRecording()")
			}
			browser.Resize()
		}
		return 0
	case 7:
		if browser != nil {
			browser.Focus()
		}
		return 0
	case 2:
		call("PostQuitMessage", 0)
		return 0
	}
	return call("DefWindowProcW", hwnd, uintptr(msg), wp, lp)
}
func main() {
	runtime.LockOSThread()
	awareness := user32.NewProc("SetProcessDpiAwarenessContext")
	if awareness.Find() == nil {
		_, _, _ = awareness.Call(^uintptr(3))
	}
	base, err := os.UserCacheDir()
	if err != nil {
		return
	}
	root := filepath.Join(base, "Companion", "client-0.6.0")
	if err = os.MkdirAll(root, 0700); err != nil {
		return
	}
	// Materialize bundled client resources for WebView2's virtual HTTPS origin.
	err = fs.WalkDir(assets, "docs", func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		if d.IsDir() {
			return nil
		}
		rel, e := filepath.Rel("docs", path)
		if e != nil {
			return e
		}
		dest := filepath.Join(root, rel)
		if e = os.MkdirAll(filepath.Dir(dest), 0700); e != nil {
			return e
		}
		b, e := assets.ReadFile(path)
		if e != nil {
			return e
		}
		return os.WriteFile(dest, b, 0600)
	})
	if err != nil {
		showError("Не удалось распаковать интерфейс приложения.")
		return
	}
	instance, _, _ := kernel32.NewProc("GetModuleHandleW").Call(0)
	icon := call("LoadImageW", 0, uintptr(unsafe.Pointer(utf(filepath.Join(root, "icon.ico")))), 1, 0, 0, 0x10|0x40)
	black, _, _ := windows.NewLazySystemDLL("gdi32.dll").NewProc("GetStockObject").Call(4)
	cls := windowClass{Icon: icon, SmallIcon: icon, Proc: windows.NewCallback(wndProc), Instance: instance, Class: utf("CompanionMessengerNative"), Cursor: call("LoadCursorW", 0, 32512), Background: black}
	cls.Size = uint32(unsafe.Sizeof(cls))
	if call("RegisterClassExW", uintptr(unsafe.Pointer(&cls))) == 0 {
		showError("Не удалось создать окно.")
		return
	}
	window = call("CreateWindowExW", 0, uintptr(unsafe.Pointer(cls.Class)), uintptr(unsafe.Pointer(utf("Companion"))), 0x00CF0000, 80, 60, 1280, 860, 0, 0, instance, 0)
	if window == 0 {
		return
	}
	dark := int32(1)
	_, _, _ = windows.NewLazySystemDLL("dwmapi.dll").NewProc("DwmSetWindowAttribute").Call(window, 20, uintptr(unsafe.Pointer(&dark)), 4)
	call("ShowWindow", window, 5)
	call("UpdateWindow", window)
	browser = edge.NewChromium()
	browser.SetGlobalPermission(edge.CoreWebView2PermissionStateDefault)
	browser.DataPath = filepath.Join(base, "Companion", "webview-profile")
	if !browser.Embed(window) {
		showError("Требуется Microsoft Edge WebView2 Runtime. Установите его с https://developer.microsoft.com/microsoft-edge/webview2/")
		return
	}
	mapping := browser.GetICoreWebView2_3()
	if mapping == nil {
		showError("Обновите Microsoft Edge WebView2 Runtime.")
		return
	}
	if err = mapping.SetVirtualHostNameToFolderMapping("companion.local", root, edge.COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_DENY_CORS); err != nil {
		showError("Не удалось открыть ресурсы приложения.")
		return
	}
	settings, err := browser.GetSettings()
	if err == nil {
		_ = settings.PutAreDevToolsEnabled(false)
		_ = settings.PutAreDefaultContextMenusEnabled(false)
	}
	browser.Init("window.COMPANION_NATIVE='windows';")
	browser.Resize()
	browser.Navigate("https://companion.local/index.html")
	var msg message
	for {
		r := call("GetMessageW", uintptr(unsafe.Pointer(&msg)), 0, 0, 0)
		if r == 0 || r == ^uintptr(0) {
			break
		}
		call("TranslateMessage", uintptr(unsafe.Pointer(&msg)))
		call("DispatchMessageW", uintptr(unsafe.Pointer(&msg)))
	}
}
