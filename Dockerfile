FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------
# System Dependencies
# -----------------------------------------------------
RUN apt-get update && apt-get install -y \
    git python3 python3-pip sudo curl unzip xz-utils dialog \
    qemu-user-static binfmt-support \
    build-essential bc bison flex libssl-dev libelf-dev \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install flask

WORKDIR /opt
RUN git clone https://github.com/ading2210/shimboot.git

RUN mkdir -p /opt/build_output

WORKDIR /app
RUN mkdir -p templates static

# -----------------------------------------------------
# Flask Backend — Command-driven Hacker Terminal
# -----------------------------------------------------
RUN cat << 'EOF' > /app/app.py
import os
import subprocess
from flask import Flask, render_template, request, Response, send_file, jsonify

app = Flask(__name__)

SHIMBOOT_DIR = "/opt/shimboot"
OUTPUT_DIR = "/opt/build_output"

STATE = {
    "board": None,
    "desktop": None,
    "flags": []
}

VALID_BOARDS = [
    "dedede","octopus","nissa","reks","kefka","zork",
    "grunt","jacuzzi","corsola","hatch","snappy","hana"
]

VALID_DESKTOPS = [
    "xfce","kde","lxde","lxqt",
    "gnome","gnome-flashback","cinnamon","mate"
]

MOTD = r"""
   __  __      _            ____              _   
  / / / /___  (_)___  ___  / __ )____  ____ _| |__
 / / / / __ \/ / __ \/ _ \/ __  / __ \/ __ `/ / _ \
/ /_/ / / / / / / / /  __/ /_/ / /_/ / /_/ / /  __/
\____/_/ /_/_/_/ /_/\___/_____/\____/\__, /_/\___/ 
                                   /____/          
         ChromeOS Shimboot Black ICE Console
"""


HELP_TEXT = r"""
AVAILABLE COMMANDS
----------------------------------------------------------------
board <name>       - Set ChromeOS board (type 'boards' to list)
desktop <name>     - Set desktop environment (type 'desktops')
flag <option>      - Add a build flag (e.g. flag luks=1)
flags_clear        - Clear all previously added flags
status             - Show current build configuration
build              - Start Shimboot build pipeline
download           - Download the latest built image
boards             - List known board names
desktops           - List valid desktop environments
motd               - Show banner / MOTD
about              - Show about info
clear_state        - Reset current board/desktop/flags
help               - Show this help text
----------------------------------------------------------------
Example session:
  board dedede
  desktop xfce
  flag luks=1
  status
  build
  download
"""


ABOUT_TEXT = r"""
ABOUT HACKBOOT
----------------------------------------------------------------
This interface is a highly terminalized, overclocked front-end
for ading2210/shimboot, driving the 'build_complete.sh' script
inside a fully containerized environment.

All glory to:
  - Shimboot (ChromeOS RMA Shim Bootloader)
  - Debian & Linux ecosystem
  - Everyone who likes green text and blinking cursors

Nothing here is a game. Every keystroke is live ammo.
----------------------------------------------------------------
"""


@app.route("/")
def index():
    return render_template("terminal.html")


def json_output(text):
    return jsonify({"output": text})


@app.route("/command", methods=["POST"])
def command():
    """
    Handle commands from the terminal-style UI.
    """
    global STATE
    data = request.get_json(silent=True) or {}
    cmd = (data.get("command") or "").strip()

    if not cmd:
        return json_output("")

    # ----------------------------------------------------------------
    # CLEAR FRONT-END (handled client-side, but we echo for flavor)
    # ----------------------------------------------------------------
    if cmd == "clear":
        return json_output("[screen cleared]\n")

    # ----------------------------------------------------------------
    # MOTD / BANNER
    # ----------------------------------------------------------------
    if cmd == "motd":
        return json_output(MOTD + "\n")

    # ----------------------------------------------------------------
    # LIST BOARDS
    # ----------------------------------------------------------------
    if cmd == "boards":
        out = "> KNOWN BOARDS\n" + "-"*60 + "\n"
        out += "\n".join(f"  - {b}" for b in VALID_BOARDS) + "\n"
        return json_output(out)

    # ----------------------------------------------------------------
    # LIST DESKTOPS
    # ----------------------------------------------------------------
    if cmd == "desktops":
        out = "> VALID DESKTOP ENVIRONMENTS\n" + "-"*60 + "\n"
        out += "\n".join(f"  - {d}" for d in VALID_DESKTOPS) + "\n"
        return json_output(out)

    # ----------------------------------------------------------------
    # SET BOARD
    # ----------------------------------------------------------------
    if cmd.startswith("board "):
        board = cmd.split(" ", 1)[1].strip()
        if board not in VALID_BOARDS:
            return json_output(f"!! INVALID BOARD: {board}\nType 'boards' to list valid options.\n")
        STATE["board"] = board
        return json_output(f"> Board set to: {board}\n")

    # ----------------------------------------------------------------
    # SET DESKTOP
    # ----------------------------------------------------------------
    if cmd.startswith("desktop "):
        de = cmd.split(" ", 1)[1].strip()
        if de not in VALID_DESKTOPS:
            return json_output(f"!! INVALID DESKTOP: {de}\nType 'desktops' to list valid options.\n")
        STATE["desktop"] = de
        return json_output(f"> Desktop set to: {de}\n")

    # ----------------------------------------------------------------
    # ADD FLAG
    # ----------------------------------------------------------------
    if cmd.startswith("flag "):
        flag = cmd.split(" ", 1)[1].strip()
        if flag:
            STATE["flags"].append(flag)
            return json_output(f"> Added flag: {flag}\n")
        return json_output("!! No flag supplied.\n")

    # ----------------------------------------------------------------
    # CLEAR FLAGS
    # ----------------------------------------------------------------
    if cmd == "flags_clear":
        STATE["flags"].clear()
        return json_output("> All flags cleared.\n")

    # ----------------------------------------------------------------
    # STATUS
    # ----------------------------------------------------------------
    if cmd == "status":
        out = [
            "> CURRENT CONFIGURATION",
            "-"*60,
            f"BOARD    : {STATE['board']}",
            f"DESKTOP  : {STATE['desktop']}",
            f"FLAGS    : {' '.join(STATE['flags']) if STATE['flags'] else '(none)'}",
            "-"*60,
            ""
        ]
        return json_output("\n".join(out))

    # ----------------------------------------------------------------
    # CLEAR STATE
    # ----------------------------------------------------------------
    if cmd == "clear_state":
        STATE["board"] = None
        STATE["desktop"] = None
        STATE["flags"].clear()
        return json_output("> State reset: board, desktop and flags cleared.\n")

    # ----------------------------------------------------------------
    # ABOUT
    # ----------------------------------------------------------------
    if cmd == "about":
        return json_output(ABOUT_TEXT + "\n")

    # ----------------------------------------------------------------
    # HELP
    # ----------------------------------------------------------------
    if cmd == "help":
        return json_output(HELP_TEXT + "\n")

    # ----------------------------------------------------------------
    # BUILD
    # ----------------------------------------------------------------
    if cmd == "build":
        if not STATE["board"] or not STATE["desktop"]:
            return json_output("!! ERROR: board and desktop must be set before build.\n")

        full_cmd = [
            "sudo",
            "./build_complete.sh",
            STATE["board"],
            f"desktop={STATE['desktop']}"
        ] + STATE["flags"]

        def stream():
            yield "=== SHIMBOOT BUILD PIPELINE INITIATED ===\n"
            yield f"TARGET BOARD   : {STATE['board']}\n"
            yield f"DESKTOP ENV    : {STATE['desktop']}\n"
            yield f"EXTRA FLAGS    : {' '.join(STATE['flags']) if STATE['flags'] else '(none)'}\n"
            yield "------------------------------------------------------------\n"
            yield "Executing:\n"
            yield "  " + " ".join(full_cmd) + "\n"
            yield "------------------------------------------------------------\n\n"

            process = subprocess.Popen(
                full_cmd,
                cwd=SHIMBOOT_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1
            )

            for line in process.stdout:
                yield line

            process.wait()
            yield "\n------------------------------------------------------------\n"
            yield "BUILD PIPELINE COMPLETED.\n"
            yield "Type 'download' to retrieve the latest build artifact.\n"
            yield "------------------------------------------------------------\n"

        return Response(stream(), mimetype="text/plain; charset=utf-8")

    # ----------------------------------------------------------------
    # DOWNLOAD
    # ----------------------------------------------------------------
    if cmd == "download":
        files = sorted(
            [os.path.join(SHIMBOOT_DIR, f) for f in os.listdir(SHIMBOOT_DIR)],
            key=os.path.getmtime,
            reverse=True
        )
        for f in files:
            if f.endswith((".bin", ".img", ".zip", ".tar.gz")):
                outfile = os.path.join(OUTPUT_DIR, os.path.basename(f))
                os.rename(f, outfile)
                return jsonify({"download": os.path.basename(outfile)})
        return json_output("!! No build output found.\n")

    # ----------------------------------------------------------------
    # UNKNOWN COMMAND
    # ----------------------------------------------------------------
    return json_output(f"!! Unknown command: {cmd}\nType 'help' for available commands.\n")


@app.route("/fetch-file/<name>")
def fetch_file(name):
    path = os.path.join(OUTPUT_DIR, name)
    if not os.path.isfile(path):
        return "File not found.", 404
    return send_file(path, as_attachment=True)


if __name__ == "__main__":
    # In-container dev mode off, just a simple run
    app.run(host="0.0.0.0", port=5000)
EOF


# -----------------------------------------------------
# Terminal UI Template — Several Hundred Lines of Hacker Greatness
# -----------------------------------------------------
RUN cat << 'EOF' > /app/templates/terminal.html
<!DOCTYPE html>
<html>
<head>
<title>HACKBOOT // SHIMBOOT BLACK ICE CONSOLE</title>
<style>
html, body {
    margin: 0;
    padding: 0;
    height: 100%;
    background: #000;
    color: #00ff9c;
    font-family: "Courier New", monospace;
    overflow: hidden;
}

/* Fullscreen layout */
#root {
    position: relative;
    width: 100vw;
    height: 100vh;
    overflow: hidden;
}

/* Matrix rain canvas */
#matrix {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    z-index: 0;
}

/* CRT overlay */
#crt {
    position: absolute;
    top: 0;
    left: 0;
    width: 100%;
    height: 100%;
    pointer-events: none;
    z-index: 2;
    background:
        radial-gradient(ellipse at center, rgba(0,255,156,0.18) 0%, rgba(0,0,0,0.9) 60%, #000 100%);
    mix-blend-mode: screen;
}

/* Scanlines */
#crt::before {
    content: "";
    position: absolute;
    top:0;
    left:0;
    width:100%;
    height:100%;
    background:
        repeating-linear-gradient(
            to bottom,
            rgba(0,0,0,0.0) 0px,
            rgba(0,0,0,0.0) 1px,
            rgba(0,255,156,0.08) 2px,
            rgba(0,0,0,0.0) 3px
        );
}

/* Bezel */
#bezel {
    position: absolute;
    z-index: 3;
    top: 2vh;
    left: 4vw;
    width: 92vw;
    height: 88vh;
    box-sizing: border-box;
    border-radius: 24px;
    border: 3px solid #00ff9c;
    box-shadow:
        0 0 12px #00ff9c,
        0 0 40px rgba(0,255,156,0.4),
        inset 0 0 30px rgba(0,255,156,0.3);
    overflow: hidden;
}

/* Inner curvature effect */
#bezel-inner {
    position: relative;
    width: 100%;
    height: 100%;
    padding: 18px;
    box-sizing: border-box;
    background: radial-gradient(circle at 20% 20%, rgba(0,50,20,0.8), #000 60%);
    transform: perspective(900px) rotateX(3deg);
}

/* HUD header bar */
#hud-header {
    width: 100%;
    display: flex;
    justify-content: space-between;
    font-size: 12px;
    letter-spacing: 2px;
    margin-bottom: 8px;
    color: #80ffd0;
}

.hud-tag {
    padding: 2px 8px;
    border-radius: 4px;
    border: 1px solid #00ff9c;
    background: rgba(0,30,15,0.8);
}

/* ASCII separator */
.hud-separator {
    font-size: 10px;
    opacity: 0.7;
    margin-bottom: 5px;
}

/* Title glitch */
#hud-title {
    font-size: 18px;
    text-align: center;
    margin-bottom: 6px;
    text-shadow:
        0 0 6px #00ff9c,
        1px 0 8px rgba(255,0,200,0.5),
        -1px 0 8px rgba(0,255,255,0.5);
    animation: glitch 1.3s infinite;
}

/* Sub-status bar */
#hud-status {
    display: flex;
    justify-content: space-between;
    font-size: 11px;
    margin-bottom: 8px;
}

/* Terminal viewport */
#terminal-container {
    position: relative;
    width: 100%;
    height: calc(100% - 80px);
    border-radius: 8px;
    border: 1px solid rgba(0,255,156,0.3);
    background: rgba(0,0,0,0.85);
    box-shadow: inset 0 0 25px rgba(0,255,156,0.5);
    padding: 8px;
    box-sizing: border-box;
    display: flex;
    flex-direction: column;
}

/* Log output area */
#log {
    flex: 1;
    overflow-y: auto;
    white-space: pre-wrap;
    font-size: 15px;
    line-height: 1.3;
    text-shadow: 0 0 4px #00ff9c;
}

/* Prompt line */
#prompt-line {
    margin-top: 4px;
    font-size: 16px;
}

.prompt-label {
    color: #00ff9c;
}

.prompt-blink {
    animation: blink 0.9s infinite;
}

/* Input field */
#input {
    background: transparent;
    border: none;
    outline: none;
    color: #00ff9c;
    font-family: inherit;
    font-size: 16px;
    caret-color: #00ff9c;
    width: 80%;
}

/* Soft flicker */
@keyframes flicker {
    0%   { opacity: 0.98; }
    20%  { opacity: 1.00; }
    40%  { opacity: 0.97; }
    60%  { opacity: 1.00; }
    80%  { opacity: 0.99; }
    100% { opacity: 1.00; }
}
#bezel-inner {
    animation: flicker 0.12s infinite;
}

/* Cursor blink */
@keyframes blink {
    0% { opacity: 1; }
    50% { opacity: 0.1; }
    100% { opacity: 1; }
}

/* Glitch text */
@keyframes glitch {
    0% { text-shadow: 0 0 6px #00ff9c; }
    20% { text-shadow: -2px 0 magenta, 2px 0 cyan; }
    40% { text-shadow: 2px 2px red, -2px -2px lime; }
    60% { text-shadow: 1px -1px magenta, -1px 1px cyan; }
    80% { text-shadow: 0 0 10px #00ff9c; }
    100% { text-shadow: 0 0 6px #00ff9c; }
}

/* Mini LEDs */
.hud-led {
    display: inline-block;
    width: 8px;
    height: 8px;
    border-radius: 50%;
    margin-right: 3px;
    box-shadow: 0 0 6px #00ff9c;
}

.hud-led.red {
    background: #ff3050;
    box-shadow: 0 0 6px #ff3050;
}
.hud-led.green {
    background: #00ff9c;
}
.hud-led.yellow {
    background: #ffd000;
    box-shadow: 0 0 6px #ffd000;
}

/* Scrollbar styling */
#log::-webkit-scrollbar {
    width: 6px;
}
#log::-webkit-scrollbar-track {
    background: rgba(0,30,15,0.8);
}
#log::-webkit-scrollbar-thumb {
    background: #00ff9c;
}

/* Command echo styling */
.cmd-echo {
    color: #90ffcf;
}
.cmd-output {
    color: #00ff9c;
}

/* HUD animated pipelines / 'data' */
#hud-stream {
    font-size: 10px;
    color: #00ff9c;
    opacity: 0.7;
    margin-bottom: 4px;
}
</style>
</head>
<body>
<div id="root">
    <canvas id="matrix"></canvas>
    <div id="crt"></div>

    <div id="bezel">
        <div id="bezel-inner">
            <div id="hud-header">
                <div class="hud-tag">
                    <span class="hud-led red"></span>
                    HACKBOOT v1.0
                </div>
                <div class="hud-tag">
                    <span class="hud-led yellow"></span>
                    MODE: SHIMBOOT BLACK ICE
                </div>
                <div class="hud-tag">
                    <span class="hud-led green"></span>
                    LINK: ONLINE
                </div>
            </div>

            <div class="hud-separator">
                +--------------------------------------------------------------+
            </div>

            <div id="hud-title">
                // CHROMEOS RMA SHIMBOOT BUILD CONSOLE //
            </div>

            <div id="hud-status">
                <div id="hud-stream">
                    [DATA BUS] >>>>>> 01001000 01000001 01000011 01001011
                </div>
                <div>
                    PROFILE: <span id="hud-profile">ANONYMOUS</span> |
                    SESSION: <span id="hud-session">#A9F3</span>
                </div>
            </div>

            <div id="terminal-container">
                <div id="log"></div>
                <div id="prompt-line">
                    <span class="prompt-label">HACKBOOT@shimboot:</span>
                    <span class="prompt-label">~$</span>
                    <input id="input" autocomplete="off" />
                    <span class="prompt-label prompt-blink">█</span>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
// -------------------------------
// Matrix Rain Background
// -------------------------------
const matrixCanvas = document.getElementById("matrix");
const ctx = matrixCanvas.getContext("2d");

function resizeMatrix() {
    matrixCanvas.width = window.innerWidth;
    matrixCanvas.height = window.innerHeight;
}
window.addEventListener("resize", resizeMatrix);
resizeMatrix();

const fontSize = 18;
let columns = Math.floor(matrixCanvas.width / fontSize);
let drops = new Array(columns).fill(1);

function drawMatrix() {
    ctx.fillStyle = "rgba(0,0,0,0.08)";
    ctx.fillRect(0, 0, matrixCanvas.width, matrixCanvas.height);
    ctx.fillStyle = "#00ff9c";
    ctx.font = fontSize + "px Courier";

    for (let i = 0; i < drops.length; i++) {
        const text = String.fromCharCode(0x30A0 + Math.random() * 96);
        ctx.fillText(text, i * fontSize, drops[i] * fontSize);
        if (drops[i] * fontSize > matrixCanvas.height && Math.random() > 0.975) {
            drops[i] = 0;
        }
        drops[i]++;
    }
}
setInterval(drawMatrix, 50);

// -------------------------------
// Terminal Logic
// -------------------------------
const logEl = document.getElementById("log");
const inputEl = document.getElementById("input");

let history = [];
let historyIndex = -1;

// Typed intro
const introLines = [
    "Initializing Shimboot Black ICE console...",
    "Loading ChromeOS RMA exploitation modules...",
    "Establishing quantum-encrypted handshake with container...",
    "Syncing Debian rootfs schemas...",
    "------------------------------------------------------------",
    "Type 'help' to display command matrix.",
    ""
];

let introIndex = 0;
function printIntroLine() {
    if (introIndex >= introLines.length) return;
    appendOutput(introLines[introIndex] + "\\n");
    introIndex++;
    setTimeout(printIntroLine, 350);
}
printIntroLine();

function appendOutput(text, cls) {
    const span = document.createElement("span");
    if (cls) span.classList.add(cls);
    span.textContent = text;
    logEl.appendChild(span);
    logEl.appendChild(document.createElement("br"));
    logEl.scrollTop = logEl.scrollHeight;
}

function appendRaw(text, cls) {
    const span = document.createElement("span");
    if (cls) span.classList.add(cls);
    span.textContent = text;
    logEl.appendChild(span);
    logEl.scrollTop = logEl.scrollHeight;
}

// Handle Enter + history navigation
inputEl.addEventListener("keydown", async (e) => {
    if (e.key === "ArrowUp") {
        if (history.length > 0) {
            historyIndex = Math.max(0, historyIndex - 1);
            inputEl.value = history[historyIndex] || "";
        }
        e.preventDefault();
        return;
    }
    if (e.key === "ArrowDown") {
        if (history.length > 0) {
            historyIndex = Math.min(history.length, historyIndex + 1);
            inputEl.value = history[historyIndex] || "";
        }
        e.preventDefault();
        return;
    }

    if (e.key === "Enter") {
        const cmd = inputEl.value.trim();
        inputEl.value = "";

        if (cmd.length > 0) {
            history.push(cmd);
            historyIndex = history.length;
        }

        // Echo the command
        appendOutput("HACKBOOT@shimboot:~$ " + cmd, "cmd-echo");

        // Local clear handling (visual)
        if (cmd === "clear") {
            logEl.innerHTML = "";
            // Still send to server for nice response
        }

        // Send to backend
        const res = await fetch("/command", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ command: cmd })
        });

        const contentType = res.headers.get("content-type") || "";

        // Streaming build output
        if (contentType.startsWith("text/plain")) {
            const reader = res.body.getReader();
            const decoder = new TextDecoder();

            function readChunk() {
                reader.read().then(({ done, value }) => {
                    if (done) return;
                    const text = decoder.decode(value);
                    appendRaw(text, "cmd-output");
                    readChunk();
                });
            }
            readChunk();
        } else {
            // JSON output (status, help, etc.)
            const data = await res.json();
            if (data.output) {
                appendRaw(data.output, "cmd-output");
            }
            if (data.download) {
                // Trigger file fetch
                window.location = "/fetch-file/" + encodeURIComponent(data.download);
                appendOutput("> Downloading: " + data.download, "cmd-output");
            }
        }
    }
});

// Autofocus input
window.addEventListener("click", () => inputEl.focus());
window.addEventListener("load", () => inputEl.focus());
</script>
</body>
</html>
EOF

EXPOSE 5000
CMD ["python3", "/app/app.py"]
