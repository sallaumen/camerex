// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/camerex"
import topbar from "../vendor/topbar"

// Prende o foco do teclado dentro de um dialog (WCAG 2.4.3) e devolve o foco ao
// elemento que o abriu quando ele fecha. O foco inicial fica por conta do
// phx-mounted={JS.focus()} dos campos. Usado por CamerexWeb.UI.modal/1.
const Hooks = {
  // Conta-gotas: no clique na prévia (só quando armado), converte o ponto em
  // frações {xf,yf} DA IMAGEM (respeitando object-contain) e manda pro servidor.
  EyedropHair: {
    mounted() {
      this.el.addEventListener("click", (e) => {
        if (this.el.dataset.armed !== "true") return
        const r = this.el.getBoundingClientRect()
        const nW = this.el.naturalWidth
        const nH = this.el.naturalHeight
        const s = Math.min(r.width / nW, r.height / nH)
        const dW = nW * s
        const dH = nH * s
        const x = e.clientX - r.left - (r.width - dW) / 2
        const y = e.clientY - r.top - (r.height - dH) / 2
        if (x < 0 || y < 0 || x > dW || y > dH) return
        this.pushEvent("eyedrop_hair", {xf: x / dW, yf: y / dH})
      })
    },
  },
  // Comparador antes/depois com handle arrastável (clip-path no "antes" sobre o
  // "depois" de base). Pointer events; respeita o container inteiro como pista.
  BeforeAfter: {
    mounted() {
      this.before = this.el.querySelector("[data-reveal-before]")
      this.handle = this.el.querySelector("[data-reveal-handle]")
      this.set(50)
      this.onMove = (e) => {
        const rect = this.el.getBoundingClientRect()
        const pct = ((e.clientX - rect.left) / rect.width) * 100
        this.set(Math.max(0, Math.min(100, pct)))
      }
      this.onUp = () => {
        window.removeEventListener("pointermove", this.onMove)
        window.removeEventListener("pointerup", this.onUp)
      }
      this.onDown = (e) => {
        e.preventDefault()
        window.addEventListener("pointermove", this.onMove)
        window.addEventListener("pointerup", this.onUp)
      }
      this.el.addEventListener("pointerdown", this.onDown)
      this.handle.addEventListener("keydown", this.onKey = (e) => {
        if (e.key === "ArrowLeft") this.set(this.pct - 5)
        else if (e.key === "ArrowRight") this.set(this.pct + 5)
      })
    },
    set(pct) {
      this.pct = Math.max(0, Math.min(100, pct))
      if (this.before) this.before.style.clipPath = `inset(0 ${100 - this.pct}% 0 0)`
      if (this.handle) {
        this.handle.style.left = `${this.pct}%`
        this.handle.setAttribute("aria-valuenow", Math.round(this.pct))
      }
    },
    destroyed() {
      window.removeEventListener("pointermove", this.onMove)
      window.removeEventListener("pointerup", this.onUp)
    },
  },
  FocusTrap: {
    mounted() {
      this.previouslyFocused = document.activeElement
      this.onKeydown = (e) => {
        if (e.key !== "Tab") return
        const els = this.focusable()
        if (els.length === 0) return
        const first = els[0]
        const last = els[els.length - 1]
        if (e.shiftKey && document.activeElement === first) {
          e.preventDefault()
          last.focus()
        } else if (!e.shiftKey && document.activeElement === last) {
          e.preventDefault()
          first.focus()
        }
      }
      this.el.addEventListener("keydown", this.onKeydown)
    },
    destroyed() {
      this.el.removeEventListener("keydown", this.onKeydown)
      if (this.previouslyFocused && this.previouslyFocused.focus) {
        this.previouslyFocused.focus()
      }
    },
    focusable() {
      const sel =
        'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'
      return Array.from(this.el.querySelectorAll(sel)).filter((el) => el.offsetParent !== null)
    },
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#2bc4b2"}, barThickness: 2, shadowColor: "rgba(43, 196, 178, .4)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// copia comandos de correção do banner do Doctor (Fase 5)
window.addEventListener("camerex:copy", (event) => {
  navigator.clipboard.writeText(event.target.textContent.trim())
})

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

