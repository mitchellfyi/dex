#!/usr/bin/env bash
# Rubric for: websocket-chat
# Hardened rubric — target score ~60-75 for typical implementations.

# Helper to find a free port
_find_free_port() {
  python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(('', 0))
print(s.getsockname()[1])
s.close()
"
}

# Helper: find the server entry point
_find_ws_entry() {
  local ws="$1"
  local pkg_main
  pkg_main=$(cd "$ws" && node -e "try{console.log(require('./package.json').main||'')}catch(e){}" 2>/dev/null || true)
  if [[ -n "$pkg_main" && -f "$ws/$pkg_main" ]]; then
    echo "$pkg_main"
    return
  fi
  for f in "server.js" "src/server.js" "index.js" "src/index.js" "app.js" "src/app.js"; do
    [[ -f "$ws/$f" ]] && echo "$f" && return
  done
  echo ""
}

# Helper: kill a server process cleanly
_kill_server() {
  local pid="$1"
  kill "$pid" 2>/dev/null
  sleep 0.5
  kill -9 "$pid" 2>/dev/null || true
}

# Helper: send a WS message and capture responses using node ws client.
# Usage: _ws_exchange <port> <js_code>
# The JS code has access to: WebSocket, port, and should call process.exit when done.
_ws_exchange() {
  local port="$1"
  local js_code="$2"
  local ws_dir="$3"
  local timeout="${4:-8000}"
  cd "$ws_dir" && node -e "
const WebSocket = require('ws');
const port = $port;
$js_code
setTimeout(() => { console.log('TIMEOUT'); process.exit(1); }, $timeout);
" 2>&1 || true
}

# Helper: try sending a join message in multiple formats, return the one that works.
# This handles DK implementing different message schemas.
_try_join() {
  local port="$1"
  local ws_dir="$2"
  local room="$3"
  local nickname="$4"

  # Try multiple join formats and see which one gets a response
  local result
  result=$(_ws_exchange "$port" "
const ws = new WebSocket('ws://localhost:' + port);
const formats = [
  JSON.stringify({type:'join', room:'$room', nickname:'$nickname'}),
  JSON.stringify({action:'join', roomName:'$room', name:'$nickname'}),
  JSON.stringify({type:'join', room:'$room', name:'$nickname'}),
  JSON.stringify({type:'join', channel:'$room', nickname:'$nickname'}),
  JSON.stringify({command:'join', room:'$room', nickname:'$nickname'}),
];
let idx = 0;
let joined = false;
ws.on('open', () => {
  ws.send(formats[idx]);
});
ws.on('message', (data) => {
  const str = data.toString();
  try {
    const msg = JSON.parse(str);
    // Check if this is a success/join confirmation or system message
    if (msg.type === 'system' || msg.type === 'join' || msg.type === 'joined' ||
        msg.type === 'welcome' || msg.type === 'history' || msg.type === 'info' ||
        (msg.type === 'message' && (str.includes('joined') || str.includes('welcome'))) ||
        msg.success === true || msg.status === 'ok' || msg.event === 'joined' ||
        (Array.isArray(msg))) {
      console.log('FORMAT:' + idx);
      joined = true;
      ws.close();
      process.exit(0);
    }
    if (msg.type === 'error' || msg.error) {
      // This format was rejected, try next
      idx++;
      if (idx < formats.length) {
        ws.send(formats[idx]);
      } else {
        console.log('NONE');
        ws.close();
        process.exit(0);
      }
    }
  } catch(e) {
    // Non-JSON response — might be plain text confirmation
    if (str.toLowerCase().includes('joined') || str.toLowerCase().includes('welcome')) {
      console.log('FORMAT:' + idx);
      joined = true;
      ws.close();
      process.exit(0);
    }
  }
});
ws.on('error', () => { console.log('CONN_ERROR'); process.exit(1); });
// If no response after 3s, try the first format as default
setTimeout(() => {
  if (!joined) { console.log('FORMAT:0'); process.exit(0); }
}, 3000);
" "$ws_dir" 5000)

  # Extract format index
  local fmt_idx
  fmt_idx=$(echo "$result" | grep -oE 'FORMAT:[0-9]+' | head -1 | cut -d: -f2)
  [[ -z "$fmt_idx" ]] && fmt_idx="0"
  echo "$fmt_idx"
}

# Helper: build a join message given a format index
_join_msg() {
  local fmt="$1"
  local room="$2"
  local nick="$3"
  case "$fmt" in
    0) echo "{\"type\":\"join\",\"room\":\"$room\",\"nickname\":\"$nick\"}" ;;
    1) echo "{\"action\":\"join\",\"roomName\":\"$room\",\"name\":\"$nick\"}" ;;
    2) echo "{\"type\":\"join\",\"room\":\"$room\",\"name\":\"$nick\"}" ;;
    3) echo "{\"type\":\"join\",\"channel\":\"$room\",\"nickname\":\"$nick\"}" ;;
    4) echo "{\"command\":\"join\",\"room\":\"$room\",\"nickname\":\"$nick\"}" ;;
    *) echo "{\"type\":\"join\",\"room\":\"$room\",\"nickname\":\"$nick\"}" ;;
  esac
}

# Helper: build a chat message given a format index
_chat_msg() {
  local fmt="$1"
  local content="$2"
  case "$fmt" in
    1) echo "{\"action\":\"message\",\"content\":\"$content\"}" ;;
    4) echo "{\"command\":\"message\",\"content\":\"$content\"}" ;;
    *) echo "{\"type\":\"message\",\"content\":\"$content\"}" ;;
  esac
}

# Helper: build a leave message given a format index
_leave_msg() {
  local fmt="$1"
  case "$fmt" in
    1) echo "{\"action\":\"leave\"}" ;;
    4) echo "{\"command\":\"leave\"}" ;;
    *) echo "{\"type\":\"leave\"}" ;;
  esac
}

# Helper: build a list_rooms message given a format index
_list_rooms_msg() {
  local fmt="$1"
  case "$fmt" in
    1) echo "{\"action\":\"list_rooms\"}" ;;
    4) echo "{\"command\":\"list_rooms\"}" ;;
    *) echo "{\"type\":\"list_rooms\"}" ;;
  esac
}


rubric_correctness() {
  local ws="$1"
  local score=0

  # --- package.json exists (2 pts) ---
  [[ -f "$ws/package.json" ]] && score=$((score + 2))

  # --- npm install works (3 pts) ---
  if ! (cd "$ws" && npm install --silent >/dev/null 2>&1); then
    echo "$score"; return
  fi
  score=$((score + 3))

  # --- Has WebSocket dependency: ws or socket.io (5 pts) ---
  local has_ws_dep="no"
  if [[ -f "$ws/package.json" ]]; then
    has_ws_dep=$(python3 -c "
import json
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    if 'ws' in deps or 'socket.io' in deps or 'websocket' in deps or 'uWebSockets.js' in deps:
        print('yes')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null || true)
  fi
  [[ "$has_ws_dep" == "yes" ]] && score=$((score + 5))

  # Ensure ws is installed in workspace for our test client
  (cd "$ws" && npm install ws >/dev/null 2>&1) || true

  # Find entry point
  local entry
  entry=$(_find_ws_entry "$ws")
  [[ -z "$entry" ]] && { echo "$score"; return; }

  # --- Server starts on a configurable port (5 pts) ---
  local port
  port=$(_find_free_port)
  local server_pid=""

  (cd "$ws" && exec env PORT="$port" node "$entry") &>/dev/null &
  server_pid=$!
  sleep 2

  if ! kill -0 "$server_pid" 2>/dev/null; then
    echo "$score"; return
  fi
  score=$((score + 5))

  # Detect the message format DK used
  local fmt
  fmt=$(_try_join "$port" "$ws" "detect" "Probe")

  # --- Can connect a WebSocket client (8 pts) ---
  local connect_result
  connect_result=$(_ws_exchange "$port" "
const ws = new WebSocket('ws://localhost:' + port);
ws.on('open', () => { console.log('CONNECTED'); ws.close(); process.exit(0); });
ws.on('error', (e) => { console.log('ERROR:' + e.message); process.exit(1); });
" "$ws" 5000)
  [[ "$connect_result" == *"CONNECTED"* ]] && score=$((score + 8))

  # --- Can send a message and receive it back/broadcast (10 pts) ---
  local join_msg
  join_msg=$(_join_msg "$fmt" "testroom" "Alice")
  local chat_msg
  chat_msg=$(_chat_msg "$fmt" "Hello World")

  local msg_result
  msg_result=$(_ws_exchange "$port" "
const ws = new WebSocket('ws://localhost:' + port);
const msgs = [];
ws.on('open', () => {
  ws.send('$join_msg');
  setTimeout(() => {
    ws.send('$chat_msg');
  }, 500);
});
ws.on('message', (data) => {
  msgs.push(data.toString());
  // Look for our message echoed back
  const str = data.toString();
  if (str.includes('Hello World') || str.includes('Hello')) {
    try {
      const parsed = JSON.parse(str);
      if (parsed.content === 'Hello World' || (parsed.data && parsed.data.content === 'Hello World') ||
          parsed.text === 'Hello World' || parsed.message === 'Hello World') {
        console.log('MSG_RECEIVED');
        ws.close();
        process.exit(0);
      }
    } catch(e) {
      if (str.includes('Hello World')) {
        console.log('MSG_RECEIVED');
        ws.close();
        process.exit(0);
      }
    }
  }
});
ws.on('error', () => { console.log('ERROR'); process.exit(1); });
" "$ws" 6000)
  [[ "$msg_result" == *"MSG_RECEIVED"* ]] && score=$((score + 10))

  # --- Room support: joining a room (8 pts) ---
  local join_result
  join_result=$(_ws_exchange "$port" "
const ws = new WebSocket('ws://localhost:' + port);
ws.on('open', () => {
  ws.send('$join_msg');
});
ws.on('message', (data) => {
  const str = data.toString();
  try {
    const msg = JSON.parse(str);
    if (msg.type === 'system' || msg.type === 'join' || msg.type === 'joined' ||
        msg.type === 'welcome' || msg.type === 'history' || msg.type === 'info' ||
        msg.success || msg.event === 'joined' || Array.isArray(msg) ||
        str.toLowerCase().includes('joined') || str.toLowerCase().includes('welcome')) {
      console.log('JOINED');
      ws.close();
      process.exit(0);
    }
  } catch(e) {
    if (str.toLowerCase().includes('joined') || str.toLowerCase().includes('welcome')) {
      console.log('JOINED');
      ws.close();
      process.exit(0);
    }
  }
});
ws.on('error', () => { console.log('ERROR'); process.exit(1); });
" "$ws" 5000)
  [[ "$join_result" == *"JOINED"* ]] && score=$((score + 8))

  # --- Room support: messages only go to same room (10 pts) ---
  local join_room1
  join_room1=$(_join_msg "$fmt" "room1" "Bob")
  local join_room2
  join_room2=$(_join_msg "$fmt" "room2" "Charlie")
  local chat_room1
  chat_room1=$(_chat_msg "$fmt" "SecretRoom1Msg")

  local isolation_result
  isolation_result=$(_ws_exchange "$port" "
const ws1 = new WebSocket('ws://localhost:' + port);
const ws2 = new WebSocket('ws://localhost:' + port);
let ws2Messages = [];
let ws1Ready = false;
let ws2Ready = false;

ws1.on('open', () => {
  ws1.send('$join_room1');
  ws1Ready = true;
  if (ws2Ready) startTest();
});
ws2.on('open', () => {
  ws2.send('$join_room2');
  ws2Ready = true;
  if (ws1Ready) startTest();
});

ws2.on('message', (data) => {
  ws2Messages.push(data.toString());
});

function startTest() {
  // Wait for joins to be processed
  setTimeout(() => {
    // Send message in room1
    ws1.send('$chat_room1');
    // Wait and check if ws2 received it (it should NOT)
    setTimeout(() => {
      const leaked = ws2Messages.some(m => m.includes('SecretRoom1Msg'));
      console.log(leaked ? 'LEAKED' : 'ISOLATED');
      ws1.close();
      ws2.close();
      process.exit(0);
    }, 1500);
  }, 1000);
}

ws1.on('error', () => {});
ws2.on('error', () => {});
" "$ws" 8000)
  [[ "$isolation_result" == *"ISOLATED"* ]] && score=$((score + 10))

  # --- Nickname support: users have names (5 pts) ---
  local nick_result
  nick_result=$(_ws_exchange "$port" "
const ws1 = new WebSocket('ws://localhost:' + port);
const ws2 = new WebSocket('ws://localhost:' + port);
let ws2Msgs = [];

const joinAlice = '$(_join_msg "$fmt" "nickroom" "AliceNick")';
const joinBob = '$(_join_msg "$fmt" "nickroom" "BobNick")';
const chatMsg = '$(_chat_msg "$fmt" "NickTest")';

ws1.on('open', () => { ws1.send(joinAlice); });
ws2.on('open', () => { ws2.send(joinBob); });

ws2.on('message', (data) => {
  ws2Msgs.push(data.toString());
});

setTimeout(() => {
  ws1.send(chatMsg);
  setTimeout(() => {
    // Check if any message ws2 received contains 'AliceNick' or similar nick reference
    const hasNick = ws2Msgs.some(m =>
      m.includes('AliceNick') || m.includes('alice') || m.includes('Alice')
    );
    console.log(hasNick ? 'HAS_NICK' : 'NO_NICK');
    ws1.close();
    ws2.close();
    process.exit(0);
  }, 1000);
}, 1500);

ws1.on('error', () => {});
ws2.on('error', () => {});
" "$ws" 8000)
  [[ "$nick_result" == *"HAS_NICK"* ]] && score=$((score + 5))

  # --- Message history: new joiners get recent messages (10 pts) ---
  local join_hist
  join_hist=$(_join_msg "$fmt" "histroom" "HistUser1")
  local chat_hist
  chat_hist=$(_chat_msg "$fmt" "HistoryTestMsg")
  local join_hist2
  join_hist2=$(_join_msg "$fmt" "histroom" "HistUser2")

  local history_result
  history_result=$(_ws_exchange "$port" "
const ws1 = new WebSocket('ws://localhost:' + port);

ws1.on('open', () => {
  ws1.send('$join_hist');
});

// Send some messages first, then connect a second client
let msgsSent = false;
ws1.on('message', () => {
  if (!msgsSent) {
    msgsSent = true;
    setTimeout(() => {
      // Send a few messages to build history
      for (let i = 0; i < 3; i++) {
        ws1.send('$chat_hist');
      }
      // Now connect second client after a delay
      setTimeout(() => {
        const ws2 = new WebSocket('ws://localhost:' + port);
        let ws2Msgs = [];
        ws2.on('open', () => {
          ws2.send('$join_hist2');
        });
        ws2.on('message', (data) => {
          const str = data.toString();
          ws2Msgs.push(str);
          // Check if we received history containing our test message
          if (str.includes('HistoryTestMsg') || str.includes('history')) {
            try {
              const parsed = JSON.parse(str);
              // History might be: {type:'history', messages:[...]} or an array
              if (parsed.type === 'history' || Array.isArray(parsed.messages) ||
                  Array.isArray(parsed.history) || Array.isArray(parsed.data) ||
                  Array.isArray(parsed)) {
                console.log('HAS_HISTORY');
                ws1.close();
                ws2.close();
                process.exit(0);
              }
            } catch(e) {}
          }
          // Also check after accumulating a few messages
          setTimeout(() => {
            const anyHistory = ws2Msgs.some(m => m.includes('HistoryTestMsg'));
            console.log(anyHistory ? 'HAS_HISTORY' : 'NO_HISTORY');
            ws1.close();
            ws2.close();
            process.exit(0);
          }, 2000);
        });
        ws2.on('error', () => {});
      }, 1000);
    }, 500);
  }
});

ws1.on('error', () => { console.log('ERROR'); process.exit(1); });
" "$ws" 10000)
  [[ "$history_result" == *"HAS_HISTORY"* ]] && score=$((score + 10))

  # --- System messages on join/leave (8 pts) ---
  local sys_result
  sys_result=$(_ws_exchange "$port" "
const ws1 = new WebSocket('ws://localhost:' + port);
const ws2 = new WebSocket('ws://localhost:' + port);
let ws1Msgs = [];

const join1 = '$(_join_msg "$fmt" "sysroom" "SysUser1")';
const join2 = '$(_join_msg "$fmt" "sysroom" "SysUser2")';

ws1.on('open', () => { ws1.send(join1); });

ws1.on('message', (data) => {
  ws1Msgs.push(data.toString());
});

setTimeout(() => {
  ws2.on('open', () => { ws2.send(join2); });
  setTimeout(() => {
    // Check if ws1 received a system message about SysUser2 joining
    const hasJoinMsg = ws1Msgs.some(m => {
      const lower = m.toLowerCase();
      return (lower.includes('sysuser2') || lower.includes('sys_user2') || lower.includes('user2')) &&
             (lower.includes('join') || lower.includes('connect') || lower.includes('entered'));
    });
    // Also check if any message has type=system or type=notification
    const hasSysType = ws1Msgs.some(m => {
      try {
        const p = JSON.parse(m);
        return p.type === 'system' || p.type === 'notification' || p.type === 'info' ||
               p.type === 'event' || p.event === 'join' || p.event === 'user_joined';
      } catch(e) { return false; }
    });
    console.log((hasJoinMsg || hasSysType) ? 'SYS_MSG' : 'NO_SYS_MSG');
    ws1.close();
    ws2.close();
    process.exit(0);
  }, 1500);
}, 1000);

ws1.on('error', () => {});
ws2.on('error', () => {});
" "$ws" 8000)
  [[ "$sys_result" == *"SYS_MSG"* ]] && score=$((score + 8))

  # --- Disconnect handling: other users notified (8 pts) ---
  local disc_result
  disc_result=$(_ws_exchange "$port" "
const ws1 = new WebSocket('ws://localhost:' + port);
const ws2 = new WebSocket('ws://localhost:' + port);
let ws1Msgs = [];

const join1 = '$(_join_msg "$fmt" "discroom" "StayUser")';
const join2 = '$(_join_msg "$fmt" "discroom" "LeaveUser")';

ws1.on('open', () => { ws1.send(join1); });

ws1.on('message', (data) => {
  ws1Msgs.push(data.toString());
});

setTimeout(() => {
  ws2.on('open', () => {
    ws2.send(join2);
    // After joining, disconnect ws2
    setTimeout(() => {
      ws2.close();
      // Check if ws1 received a leave/disconnect notification
      setTimeout(() => {
        const hasLeaveMsg = ws1Msgs.some(m => {
          const lower = m.toLowerCase();
          return (lower.includes('leaveuser') || lower.includes('leave_user') || lower.includes('left') ||
                  lower.includes('disconnect') || lower.includes('departed'));
        });
        console.log(hasLeaveMsg ? 'DISC_NOTIFIED' : 'NO_DISC_NOTIFY');
        ws1.close();
        process.exit(0);
      }, 1500);
    }, 1000);
  });
  ws2.on('error', () => {});
}, 1000);

ws1.on('error', () => {});
" "$ws" 10000)
  [[ "$disc_result" == *"DISC_NOTIFIED"* ]] && score=$((score + 8))

  # --- List rooms endpoint or command (5 pts) ---
  local list_msg
  list_msg=$(_list_rooms_msg "$fmt")
  local join_for_list
  join_for_list=$(_join_msg "$fmt" "listedroom" "Lister")

  local list_result
  list_result=$(_ws_exchange "$port" "
const ws = new WebSocket('ws://localhost:' + port);
ws.on('open', () => {
  // Join a room first so there's at least one
  ws.send('$join_for_list');
  setTimeout(() => {
    ws.send('$list_msg');
  }, 500);
});
ws.on('message', (data) => {
  const str = data.toString();
  try {
    const msg = JSON.parse(str);
    if (msg.type === 'room_list' || msg.type === 'rooms' || msg.type === 'list' ||
        msg.type === 'list_rooms' ||
        Array.isArray(msg.rooms) || Array.isArray(msg.data) ||
        (msg.rooms && typeof msg.rooms === 'object')) {
      console.log('HAS_LIST');
      ws.close();
      process.exit(0);
    }
  } catch(e) {}
});
ws.on('error', () => { console.log('ERROR'); process.exit(1); });
" "$ws" 5000)
  [[ "$list_result" == *"HAS_LIST"* ]] && score=$((score + 5))

  # --- Multiple concurrent connections work (8 pts) ---
  local concurrent_result
  concurrent_result=$(_ws_exchange "$port" "
const clients = [];
let connected = 0;
let errors = 0;
const NUM = 5;

for (let i = 0; i < NUM; i++) {
  const ws = new WebSocket('ws://localhost:' + port);
  ws.on('open', () => {
    connected++;
    const joinMsg = JSON.parse('$(_join_msg "$fmt" "concroom" "User")');
    joinMsg.nickname = 'ConcUser' + i;
    if (joinMsg.name !== undefined) joinMsg.name = 'ConcUser' + i;
    ws.send(JSON.stringify(joinMsg));
    if (connected === NUM) {
      setTimeout(() => {
        console.log(errors === 0 ? 'CONCURRENT_OK' : 'CONCURRENT_FAIL');
        clients.forEach(c => c.close());
        process.exit(0);
      }, 1000);
    }
  });
  ws.on('error', () => { errors++; });
  clients.push(ws);
}
" "$ws" 10000)
  [[ "$concurrent_result" == *"CONCURRENT_OK"* ]] && score=$((score + 8))

  # --- Messages have timestamps (5 pts) ---
  local ts_result
  ts_result=$(_ws_exchange "$port" "
const ws = new WebSocket('ws://localhost:' + port);
const joinMsg = '$(_join_msg "$fmt" "tsroom" "TsUser")';
const chatMsg = '$(_chat_msg "$fmt" "TimestampTest")';
let msgs = [];

ws.on('open', () => {
  ws.send(joinMsg);
  setTimeout(() => { ws.send(chatMsg); }, 500);
});

ws.on('message', (data) => {
  const str = data.toString();
  msgs.push(str);
  try {
    const msg = JSON.parse(str);
    // Check for timestamp fields
    if (msg.timestamp || msg.time || msg.createdAt || msg.created_at ||
        msg.sentAt || msg.sent_at || msg.date || msg.ts) {
      console.log('HAS_TS');
      ws.close();
      process.exit(0);
    }
    // Check nested data
    if (msg.data && (msg.data.timestamp || msg.data.time || msg.data.createdAt)) {
      console.log('HAS_TS');
      ws.close();
      process.exit(0);
    }
  } catch(e) {}
});
ws.on('error', () => {});
// After collecting messages, check them all
setTimeout(() => {
  const anyTs = msgs.some(m => {
    try {
      const p = JSON.parse(m);
      return p.timestamp || p.time || p.createdAt || p.created_at || p.sentAt || p.ts || p.date;
    } catch(e) { return false; }
  });
  console.log(anyTs ? 'HAS_TS' : 'NO_TS');
  ws.close();
  process.exit(0);
}, 3000);
" "$ws" 5000)
  [[ "$ts_result" == *"HAS_TS"* ]] && score=$((score + 5))

  # Cleanup
  _kill_server "$server_pid"

  echo "$score"
}


rubric_test_quality() {
  local ws="$1"
  local score=0

  # Ensure deps are installed
  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true
  # Ensure ws is available for tests
  (cd "$ws" && npm install ws >/dev/null 2>&1) || true

  # --- Test files exist (15 pts) ---
  local test_files
  test_files=$(find "$ws" -maxdepth 4 \( \
    -name "*.test.*" -o -name "*.spec.*" -o \
    -name "test.js" -o -name "test_*.js" -o -name "tests.js" \
  \) ! -path "*/node_modules/*" 2>/dev/null || true)
  local _test_dir_files
  _test_dir_files=$(find "$ws" -maxdepth 4 \( -path "*/__tests__/*.js" -o -path "*/test/*.js" -o -path "*/tests/*.js" \) ! -path "*/node_modules/*" 2>/dev/null || true)
  [[ -n "$_test_dir_files" ]] && test_files=$(printf '%s\n%s' "$test_files" "$_test_dir_files" | sort -u | grep -v '^$')
  local test_count
  test_count=$(echo "$test_files" | grep -c '.' 2>/dev/null || echo "0")
  [[ $test_count -gt 0 ]] && score=$((score + 15))

  # --- Tests actually pass (25 pts) ---
  local test_output
  test_output=$(cd "$ws" && timeout 60 npm test 2>&1 | tail -60) || true
  local tests_pass
  tests_pass=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
# Look for common pass indicators
if re.search(r'(pass|PASS|Tests:.*passed|test suites.*passed|passing|✓)', text, re.IGNORECASE):
    # Also check there's no failure
    if not re.search(r'(FAIL(?!\s+0)|fail(?:ed|ure)|ERR!)', text, re.IGNORECASE):
        print('yes')
    else:
        print('no')
else:
    print('no')
" 2>/dev/null || true)
  [[ "$tests_pass" == "yes" ]] && score=$((score + 25))

  # --- Tests cover connection lifecycle: connect/disconnect (15 pts) ---
  local has_lifecycle="no"
  if [[ -n "$test_files" ]]; then
    has_lifecycle=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "connect|disconnect|close|on\(.open|\.on\(.close|lifecycle|teardown|afterAll|afterEach" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_lifecycle" == "found" ]] && score=$((score + 15))

  # --- Tests cover message broadcast (10 pts) ---
  local has_broadcast="no"
  if [[ -n "$test_files" ]]; then
    has_broadcast=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "broadcast|send.*message|receive.*message|message.*send|on\(.message|\.send\(" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_broadcast" == "found" ]] && score=$((score + 10))

  # --- Tests cover room isolation (10 pts) ---
  local has_isolation="no"
  if [[ -n "$test_files" ]]; then
    has_isolation=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "room.*isolat|different.*room|only.*same.*room|not.*receive|should.*not.*get|room.*separation|cross.*room|other.*room" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    # Fallback: check for multiple room references in test
    if [[ "$has_isolation" != "found" ]]; then
      has_isolation=$(echo "$test_files" | while read -r f; do
        [[ -z "$f" ]] && continue
        local room_refs
        room_refs=$(grep -ciE "room" "$f" 2>/dev/null) || room_refs=0
        if [[ "$room_refs" -ge 3 ]]; then
          echo "found"; break
        fi
      done) || true
    fi
  fi
  [[ "$has_isolation" == "found" ]] && score=$((score + 10))

  # --- Tests cover message history (10 pts) ---
  local has_history_test="no"
  if [[ -n "$test_files" ]]; then
    has_history_test=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "history|recent.*message|past.*message|previous.*message|backlog" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_history_test" == "found" ]] && score=$((score + 10))

  # --- Test count > 5 (5 pts), > 10 (additional 5 pts) ---
  local individual_tests
  individual_tests=$(echo "$test_output" | python3 -c "
import sys, re
text = sys.stdin.read()
# Jest: 'Tests: X passed'
m = re.search(r'Tests:\s+(\d+)\s+passed', text)
if m:
    print(m.group(1)); exit()
# Mocha/tap: '(\d+) passing'
m = re.search(r'(\d+)\s+passing', text)
if m:
    print(m.group(1)); exit()
# Count checkmarks or 'PASS' lines
count = len(re.findall(r'[✓✔]|PASS\s', text))
print(count if count > 0 else 0)
" 2>/dev/null || true)
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 5 ]] 2>/dev/null && score=$((score + 5))
  [[ -n "$individual_tests" ]] && [[ "$individual_tests" -gt 10 ]] 2>/dev/null && score=$((score + 5))

  # --- Has concurrent client tests (5 pts) ---
  local has_concurrent="no"
  if [[ -n "$test_files" ]]; then
    has_concurrent=$(echo "$test_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlEi "Promise\.all|concurrent|parallel|multiple.*client|multiple.*connection|several.*client|Promise\.allSettled" "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
  fi
  [[ "$has_concurrent" == "found" ]] && score=$((score + 5))

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}


rubric_robustness() {
  local ws="$1"
  local score=0

  # Ensure deps installed
  (cd "$ws" && npm install --silent >/dev/null 2>&1) || true
  (cd "$ws" && npm install ws >/dev/null 2>&1) || true

  local src_files
  src_files=$(find "$ws" -maxdepth 4 -name "*.js" ! -path "*/node_modules/*" ! -name "*.test.*" ! -name "*.spec.*" 2>/dev/null || true)

  # --- Handles client disconnection without crash (15 pts) ---
  # Actually test this: connect, join, then abruptly close, then connect again
  local entry
  entry=$(_find_ws_entry "$ws")
  if [[ -n "$entry" ]]; then
    local port
    port=$(_find_free_port)
    (cd "$ws" && exec env PORT="$port" node "$entry") &>/dev/null &
    local server_pid=$!
    sleep 2

    if kill -0 "$server_pid" 2>/dev/null; then
      local crash_result
      crash_result=$(_ws_exchange "$port" "
const ws1 = new WebSocket('ws://localhost:' + port);
ws1.on('open', () => {
  ws1.send(JSON.stringify({type:'join',room:'crashtest',nickname:'Crasher'}));
  setTimeout(() => {
    ws1.terminate(); // Abrupt close
    // Now try connecting again
    setTimeout(() => {
      const ws2 = new WebSocket('ws://localhost:' + port);
      ws2.on('open', () => {
        ws2.send(JSON.stringify({type:'join',room:'crashtest',nickname:'Survivor'}));
        setTimeout(() => {
          console.log('NO_CRASH');
          ws2.close();
          process.exit(0);
        }, 500);
      });
      ws2.on('error', () => { console.log('CRASHED'); process.exit(1); });
    }, 1000);
  }, 500);
});
ws1.on('error', () => {});
" "$ws" 8000)
      [[ "$crash_result" == *"NO_CRASH"* ]] && score=$((score + 15))

      _kill_server "$server_pid"
    else
      kill -9 "$server_pid" 2>/dev/null || true
    fi
  fi

  # --- Has message format validation (10 pts) ---
  local has_validation="no"
  has_validation=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "JSON\.parse|invalid.*message|malformed|validation|validate|schema|typeof.*type|!.*type|missing.*type|required.*field" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_validation" == "found" ]] && score=$((score + 10))

  # --- Limits message history size (10 pts) ---
  local has_limit="no"
  has_limit=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "\.slice\(|\.splice\(|MAX_HISTORY|maxHistory|max_history|history.*length|\.length\s*>|shift\(\)|limit.*50|50.*limit|MAX_MESSAGES|maxMessages" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_limit" == "found" ]] && score=$((score + 10))

  # --- Has heartbeat/ping-pong (10 pts) ---
  local has_heartbeat="no"
  has_heartbeat=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "heartbeat|ping|pong|isAlive|keepalive|keep.alive|setInterval.*ping|\.ping\(" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_heartbeat" == "found" ]] && score=$((score + 10))

  # --- Sanitizes user input (nickname, message content) (10 pts) ---
  local has_sanitize="no"
  has_sanitize=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "sanitiz|escape|xss|\.trim\(\)|\.replace\(|htmlentit|DOMPurify|strip.*tag|encode|validator|length.*check|maxLength|max_length" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_sanitize" == "found" ]] && score=$((score + 10))

  # --- Uses const/let, no var (5 pts) ---
  local has_var="no"
  has_var=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qE '\bvar\s' "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_var" != "found" ]] && score=$((score + 5))

  # --- No console.log in source (except logging library) (5 pts) ---
  # Allow console.log only if a logging library is present
  local has_logger="no"
  has_logger=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "winston|pino|bunyan|log4js|morgan|signale|loglevel" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  if [[ "$has_logger" != "found" && -f "$ws/package.json" ]]; then
    has_logger=$(python3 -c "
import json
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    loggers = [k for k in deps if k in ('winston','pino','bunyan','log4js','morgan','signale','loglevel')]
    print('found' if loggers else '')
except:
    print('')
" 2>/dev/null || true)
  fi

  if [[ "$has_logger" == "found" ]]; then
    # Has a logging library — give the points
    score=$((score + 5))
  else
    # Check for console.log in source files (excluding test files)
    local has_console_log="no"
    has_console_log=$(echo "$src_files" | while read -r f; do
      [[ -z "$f" ]] && continue
      if grep -qlE 'console\.log' "$f" 2>/dev/null; then
        echo "found"; break
      fi
    done) || true
    [[ "$has_console_log" != "found" ]] && score=$((score + 5))
  fi

  # --- Has error handling for malformed messages (10 pts) ---
  local has_error_handling="no"
  has_error_handling=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "try\s*\{|catch\s*\(|JSON\.parse.*catch|error.*handler|\.on\(.error|on.*error" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_error_handling" == "found" ]] && score=$((score + 10))

  # --- Separate files for server and logic (5 pts) ---
  local js_file_count
  js_file_count=$(echo "$src_files" | grep -c '.' 2>/dev/null || echo "0")
  [[ "$js_file_count" -ge 2 ]] && score=$((score + 5))

  # --- Has configurable port (via env) (5 pts) ---
  local has_port_config="no"
  has_port_config=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "process\.env\.PORT|process\.env\[.PORT.\]|env\.PORT|PORT.*3000|3000.*PORT" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_port_config" == "found" ]] && score=$((score + 5))

  # --- Clean shutdown handler (5 pts) ---
  local has_shutdown="no"
  has_shutdown=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlE "SIGTERM|SIGINT|process\.on|server\.close|graceful|\.close\(\)" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  [[ "$has_shutdown" == "found" ]] && score=$((score + 5))

  # --- Connection limit or rate limiting (10 pts) ---
  local has_rate_limit="no"
  has_rate_limit=$(echo "$src_files" | while read -r f; do
    [[ -z "$f" ]] && continue
    if grep -qlEi "rate.?limit|max.?connect|connection.?limit|maxPayload|max.?client|throttle|backpressure|maxConnections|perMessageDeflate" "$f" 2>/dev/null; then
      echo "found"; break
    fi
  done) || true
  if [[ "$has_rate_limit" != "found" && -f "$ws/package.json" ]]; then
    has_rate_limit=$(python3 -c "
import json
try:
    data = json.load(open('$ws/package.json'))
    deps = {**data.get('dependencies',{}), **data.get('devDependencies',{})}
    limiters = [k for k in deps if 'rate' in k.lower() or 'limit' in k.lower() or 'throttle' in k.lower()]
    print('found' if limiters else '')
except:
    print('')
" 2>/dev/null || true)
  fi
  [[ "$has_rate_limit" == "found" ]] && score=$((score + 10))

  # Cap at 100
  [[ $score -gt 100 ]] && score=100

  echo "$score"
}
