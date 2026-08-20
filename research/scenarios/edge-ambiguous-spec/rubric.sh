#!/usr/bin/env bash
# Rubric for: edge-ambiguous-spec
# HARDENED v2: target ~60-75 for typical implementations.
# The prompt is deliberately vague ("Build a rate limiter.").
# Tests whether DX makes GOOD assumptions, produces professional-grade code,
# and handles the ambiguity intelligently (not just minimally).

rubric_correctness() {
  local ws="$1"
  local score=0

  # Something was created (any code files)
  local code_files
  code_files=$(find "$ws" -maxdepth 4 \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" -o -name "*.rs" \) ! -path "*/node_modules/*" ! -path "*/.venv/*" 2>/dev/null | wc -l | tr -d ' ')
  [[ $code_files -gt 0 ]] && score=$((score + 5))

  # Has a package/module file
  local has_manifest=false
  for f in "package.json" "go.mod" "Cargo.toml" "setup.py" "pyproject.toml" "requirements.txt"; do
    [[ -f "$ws/$f" ]] && has_manifest=true && break
  done
  $has_manifest && score=$((score + 5))

  local all_src
  all_src=$(find "$ws" -maxdepth 4 \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" \) ! -path "*/node_modules/*" 2>/dev/null)

  # Has allow/deny or similar limit checking logic
  if echo "$all_src" | xargs grep -qliE "allow|deny|limit|exceed|throttle|window|bucket|token" 2>/dev/null; then
    score=$((score + 8))
  fi

  # Has configurable limits
  if echo "$all_src" | xargs grep -qliE "max.*request|window.*size|limit.*config|rate.*config|tokens.*per|requests.*per" 2>/dev/null; then
    score=$((score + 7))
  fi

  # Actually runnable — try to build/install
  local builds=false
  if [[ -f "$ws/package.json" ]]; then
    (cd "$ws" && npm install --silent >/dev/null 2>&1) && builds=true
  elif [[ -f "$ws/go.mod" ]]; then
    (cd "$ws" && go build ./... 2>/dev/null) && builds=true
  elif [[ -f "$ws/requirements.txt" ]] || [[ -f "$ws/setup.py" ]]; then
    builds=true
  fi
  $builds && score=$((score + 10))

  # Tests exist and pass
  local tests_pass=false
  if [[ -f "$ws/package.json" ]] && grep -q '"test"' "$ws/package.json" 2>/dev/null; then
    local _npm_out; _npm_out=$(cd "$ws" && npm test 2>&1 | tail -10) || true
    grep -qiE "pass|ok|success" <<< "${_npm_out}" && tests_pass=true
  elif [[ -f "$ws/go.mod" ]]; then
    local _go_out; _go_out=$(cd "$ws" && go test ./... 2>&1) || true
    [[ "$_go_out" == *"PASS"* ]] && tests_pass=true
  elif grep -q "\.py$" <<< "$(head -1 <<< "$all_src")" 2>/dev/null; then
    local _py_out; _py_out=$(cd "$ws" && python3 -m pytest 2>&1) || true
    [[ "$_py_out" == *"passed"* ]] || [[ "$_py_out" == *"ok"* ]] && tests_pass=true
  fi
  $tests_pass && score=$((score + 10))

  # Has a clear API (exported function/class for rate limiting)
  if echo "$all_src" | xargs grep -qliE "class RateLimiter|class.*Limiter|function.*rateLimi|func.*RateLimit|def rate_limit|export.*RateLimit|export.*Limiter|createLimiter" 2>/dev/null; then
    score=$((score + 10))
  fi

  # HARDER: Implements multiple algorithms or strategies
  local algorithms=0
  for algo in "fixed.*window|fixedWindow" "sliding.*window|slidingWindow" "token.*bucket|tokenBucket" "leaky.*bucket|leakyBucket"; do
    if echo "$all_src" | xargs grep -qliE "$algo" 2>/dev/null; then
      algorithms=$((algorithms + 1))
    fi
  done
  [[ $algorithms -ge 1 ]] && score=$((score + 8))
  [[ $algorithms -ge 2 ]] && score=$((score + 7))

  # HARDER: Rate limiter actually works (functional test)
  # Build TypeScript first if needed (ESM/TS modules need compilation for require())
  if [[ -f "$ws/tsconfig.json" ]] && grep -q '"build"' "$ws/package.json" 2>/dev/null; then
    (cd "$ws" && npm run build >/dev/null 2>&1) || true
  fi
  # Try to import and use it
  if [[ -f "$ws/package.json" ]]; then
    local func_test
    func_test=$(cd "$ws" && node -e "
// Try to find and use the rate limiter
let mod;
try {
  for (const p of ['./src/index', './src/rate-limiter', './src/rateLimiter', './index', './src', './dist/index']) {
    try { mod = require(p); break; } catch(e) {}
  }
  if (!mod) { console.log('NO_IMPORT'); process.exit(); }

  // Resolve to a constructable class — try multiple patterns
  let Cls = null;
  if (typeof mod === 'function') {
    Cls = mod;
  } else if (typeof mod === 'object') {
    // Try common named exports
    for (const k of ['RateLimiter', 'default', 'FixedWindowLimiter', 'SlidingWindowLimiter',
                      'TokenBucketLimiter', 'FixedWindowRateLimiter', 'SlidingWindowRateLimiter',
                      'TokenBucketRateLimiter', 'Limiter', 'RateLimit']) {
      if (typeof mod[k] === 'function') { Cls = mod[k]; break; }
    }
    // Try factory function
    const factoryFn = mod.createLimiter || mod.createRateLimiter || mod.create;
    if (!Cls && typeof factoryFn === 'function') {
      let limiter;
      for (const algo of ['fixed-window', 'fixedWindow', 'sliding-window', 'token-bucket', undefined]) {
        try {
          limiter = factoryFn({algorithm: algo, type: algo, maxRequests: 3, windowMs: 1000, windowSize: 1000, limit: 3, tokensPerInterval: 3, interval: 1000});
          if (limiter) break;
        } catch(e) {}
        try {
          limiter = factoryFn(algo, {maxRequests: 3, windowMs: 1000, windowSize: 1000, limit: 3, tokensPerInterval: 3, interval: 1000});
          if (limiter) break;
        } catch(e) {}
      }
      if (limiter) {
        const check = (key) => limiter.isAllowed ? limiter.isAllowed(key) :
                     limiter.allow ? limiter.allow(key) :
                     limiter.check ? limiter.check(key) :
                     limiter.consume ? limiter.consume(key) :
                     limiter.tryConsume ? limiter.tryConsume(key) : null;
        let allowed = 0;
        for (let i = 0; i < 5; i++) {
          const r = check('test-client');
          if (r === true || (r && r.allowed)) allowed++;
        }
        console.log(allowed <= 3 ? 'PASS' : 'FAIL:' + allowed);
        process.exit();
      }
    }
  }
  if (!Cls) { console.log('NO_CONSTRUCT'); process.exit(); }

  // Try construction with various config shapes.
  // Include all common param names so the limit is actually recognized.
  let limiter = null;
  const cfg = {maxRequests: 3, limit: 3, windowMs: 1000, window: 1000,
               tokens: 3, interval: 1000, windowSize: 1000, capacity: 3,
               max: 3, rate: 3, points: 3, duration: 1};
  try { limiter = new Cls(cfg); } catch(e) {}
  if (!limiter) { console.log('NO_INSTANCE'); process.exit(); }

  const key = 'test-client';
  let allowed = 0;
  for (let i = 0; i < 5; i++) {
    const result = limiter.isAllowed ? limiter.isAllowed(key) :
                   limiter.allow ? limiter.allow(key) :
                   limiter.check ? limiter.check(key) :
                   limiter.consume ? limiter.consume(key) :
                   limiter.tryConsume ? limiter.tryConsume(key) : null;
    if (result === true || (result && result.allowed)) allowed++;
  }
  console.log(allowed <= 3 ? 'PASS' : 'FAIL:' + allowed);
} catch(e) {
  console.log('ERROR:' + e.message);
}
" 2>&1) || true
    [[ "$func_test" == *"PASS"* ]] && score=$((score + 15))
  fi

  # HARDER: Per-client isolation (different clients get their own limits)
  if [[ -f "$ws/package.json" ]]; then
    local isolation_test
    isolation_test=$(cd "$ws" && node -e "
let mod;
try {
  for (const p of ['./src/index', './src/rate-limiter', './src/rateLimiter', './index', './src', './dist/index']) {
    try { mod = require(p); break; } catch(e) {}
  }
  if (!mod) { console.log('NO_IMPORT'); process.exit(); }

  // Resolve to a constructable class or factory
  let limiter = null;
  const iCfg = {maxRequests:2,limit:2,windowMs:60000,window:60000,tokens:2,interval:60000,windowSize:60000,capacity:2,max:2,rate:2,points:2,duration:60};
  if (typeof mod === 'function') {
    try { limiter = new mod(iCfg); } catch(e) {}
  } else if (typeof mod === 'object') {
    // Try factory
    const factoryFn2 = mod.createLimiter || mod.createRateLimiter || mod.create;
    if (typeof factoryFn2 === 'function') {
      for (const algo of ['fixed-window','fixedWindow','sliding-window','token-bucket',undefined]) {
        try { limiter = factoryFn2({...iCfg, algorithm:algo, type:algo}); if(limiter) break; } catch(e) {}
        try { limiter = factoryFn2(algo, iCfg); if(limiter) break; } catch(e) {}
      }
    }
    // Try named classes
    if (!limiter) {
      for (const k of ['RateLimiter','default','FixedWindowLimiter','SlidingWindowLimiter','TokenBucketLimiter','FixedWindowRateLimiter','SlidingWindowRateLimiter','TokenBucketRateLimiter','Limiter']) {
        if (typeof mod[k] === 'function') {
          try { limiter = new mod[k](iCfg); } catch(e) {}
          if (limiter) break;
        }
      }
    }
  }
  if (!limiter) { console.log('NO_LIMITER'); process.exit(); }

  const check = (key) => limiter.isAllowed ? limiter.isAllowed(key) :
                          limiter.allow ? limiter.allow(key) :
                          limiter.check ? limiter.check(key) :
                          limiter.consume ? limiter.consume(key) :
                          limiter.tryConsume ? limiter.tryConsume(key) : null;

  check('client-a');
  check('client-a');
  const bResult = check('client-b');
  console.log(bResult === true || (bResult && bResult.allowed) ? 'PASS' : 'FAIL');
} catch(e) {
  console.log('ERROR:' + e.message);
}
" 2>&1) || true
    [[ "$isolation_test" == *"PASS"* ]] && score=$((score + 10))
  fi

  # README or documentation exists
  [[ -f "$ws/README.md" ]] && score=$((score + 3))

  # HARDER: Time window boundary test — make requests up to limit, wait for window reset,
  # verify new requests are allowed (8 pts)
  if [[ -f "$ws/package.json" ]]; then
    local window_test
    window_test=$(cd "$ws" && timeout 6 node -e "
let mod;
try {
  for (const p of ['./src/index','./src/rate-limiter','./src/rateLimiter','./index','./src','./dist/index']) {
    try { mod = require(p); break; } catch(e) {}
  }
  if (!mod) { console.log('NO_IMPORT'); process.exit(); }

  // Build a limiter with a very short window (500ms) and limit of 2
  const cfg = {maxRequests:2,limit:2,windowMs:500,window:500,tokens:2,interval:500,windowSize:500,capacity:2,max:2,rate:2,points:2,duration:0.5};
  let limiter = null;

  // Try factory
  const factoryFn3 = (typeof mod === 'object') ? (mod.createLimiter || mod.createRateLimiter || mod.create) : null;
  if (!limiter && typeof factoryFn3 === 'function') {
    for (const algo of ['fixed-window','fixedWindow','sliding-window','token-bucket',undefined]) {
      try { limiter = factoryFn3({...cfg, algorithm:algo, type:algo}); if(limiter) break; } catch(e) {}
      try { limiter = factoryFn3(algo, cfg); if(limiter) break; } catch(e) {}
    }
  }
  // Try class
  if (!limiter) {
    let Cls = typeof mod === 'function' ? mod : null;
    if (!Cls && typeof mod === 'object') {
      for (const k of ['RateLimiter','default','FixedWindowLimiter','SlidingWindowLimiter','TokenBucketLimiter','FixedWindowRateLimiter','SlidingWindowRateLimiter','TokenBucketRateLimiter','Limiter','RateLimit']) {
        if (typeof mod[k] === 'function') { Cls = mod[k]; break; }
      }
    }
    if (Cls) { try { limiter = new Cls(cfg); } catch(e) {} }
  }
  if (!limiter) { console.log('NO_LIMITER'); process.exit(); }

  const check = (key) => {
    const r = limiter.isAllowed ? limiter.isAllowed(key) :
              limiter.allow ? limiter.allow(key) :
              limiter.check ? limiter.check(key) :
              limiter.consume ? limiter.consume(key) :
              limiter.tryConsume ? limiter.tryConsume(key) : null;
    return r === true || (r && r.allowed);
  };

  // Use up the limit
  check('window-test');
  check('window-test');
  // Third should be denied
  const denied = !check('window-test');
  if (!denied) { console.log('FAIL_NOT_DENIED'); process.exit(); }

  // Wait for window to reset (600ms > 500ms window)
  setTimeout(() => {
    const afterReset = check('window-test');
    console.log(afterReset ? 'PASS' : 'FAIL_NOT_RESET');
    process.exit();
  }, 700);
" 2>&1) || true
    [[ "$window_test" == *"PASS"* ]] && score=$((score + 8))
  fi

  # HARDER: HTTP middleware test — if Express/Koa middleware is exported, verify it blocks requests (7 pts)
  if [[ -f "$ws/package.json" ]]; then
    local middleware_test
    middleware_test=$(cd "$ws" && timeout 5 node -e "
let mod;
try {
  for (const p of ['./src/index','./src/rate-limiter','./src/rateLimiter','./index','./src','./dist/index','./src/middleware']) {
    try { mod = require(p); break; } catch(e) {}
  }
  if (!mod) { console.log('NO_IMPORT'); process.exit(); }

  // Look for middleware export (function that returns (req,res,next))
  let mw = null;
  if (typeof mod === 'object') {
    for (const k of ['middleware','rateLimitMiddleware','createMiddleware','expressMiddleware','rateLimit']) {
      if (typeof mod[k] === 'function') {
        try {
          const result = mod[k]({maxRequests:2,limit:2,windowMs:60000,window:60000,max:2});
          if (typeof result === 'function') { mw = result; break; }
        } catch(e) {}
      }
    }
  }
  // Also check if mod itself is a middleware factory
  if (!mw && typeof mod === 'function') {
    try {
      const result = mod({maxRequests:2,limit:2,windowMs:60000,window:60000,max:2});
      if (typeof result === 'function' && result.length >= 2) { mw = result; }
    } catch(e) {}
  }
  if (!mw) { console.log('NO_MIDDLEWARE'); process.exit(); }

  // Simulate Express req/res/next
  let blocked = false;
  let passed = 0;
  const fakeReq = (ip) => ({ip, headers:{'x-forwarded-for':ip}, connection:{remoteAddress:ip}});
  const fakeRes = () => {
    const r = {statusCode:200, headers:{},
      status(c){r.statusCode=c;return r},
      set(k,v){r.headers[k]=v;return r},
      setHeader(k,v){r.headers[k]=v;return r},
      json(d){return r}, send(d){return r}, end(){return r}};
    return r;
  };
  const fakeNext = () => { passed++; };

  // Call middleware 3 times for same IP (limit is 2)
  for (let i = 0; i < 3; i++) {
    const res = fakeRes();
    try { mw(fakeReq('1.2.3.4'), res, fakeNext); } catch(e) {}
    if (res.statusCode === 429) blocked = true;
  }
  console.log(passed <= 2 && blocked ? 'PASS' : 'FAIL:passed=' + passed + ',blocked=' + blocked);
" 2>&1) || true
    [[ "$middleware_test" == *"PASS"* ]] && score=$((score + 7))
  fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0

  local test_files
  test_files=$(find "$ws" -maxdepth 4 \( -name "*.test.*" -o -name "*.spec.*" -o -name "*_test.*" -o -name "test_*" \) ! -path "*/node_modules/*" 2>/dev/null)
  local test_count
  test_count=$(echo "$test_files" | grep -c . 2>/dev/null) || test_count=0
  [[ $test_count -gt 0 ]] && score=$((score + 15))

  # Tests pass
  if [[ -f "$ws/package.json" ]]; then
    local _npm_t; _npm_t=$(cd "$ws" && npm test 2>&1 | tail -10) || true
    grep -qiE "pass|✓|ok" <<< "${_npm_t}" && score=$((score + 25))
  elif [[ -f "$ws/go.mod" ]]; then
    local _go_t; _go_t=$(cd "$ws" && go test ./... 2>&1) || true
    [[ "$_go_t" == *"PASS"* ]] && score=$((score + 25))
  else
    local _py_t; _py_t=$(cd "$ws" && python3 -m pytest 2>&1) || true
    [[ "$_py_t" == *"passed"* ]] && score=$((score + 25))
  fi

  # Tests cover rate limiting behavior (allow/deny scenarios)
  if [[ -n "$test_files" ]] && echo "$test_files" | xargs grep -qliE "allow|deny|exceed|block|limit|throttle" 2>/dev/null; then
    score=$((score + 10))
  fi

  # Tests cover edge cases
  local edge_tested=0
  if [[ -n "$test_files" ]]; then
    echo "$test_files" | xargs grep -qliE "concurrent|simultaneous|parallel" 2>/dev/null && edge_tested=$((edge_tested + 1))
    echo "$test_files" | xargs grep -qliE "reset|expire|window.*end|clean" 2>/dev/null && edge_tested=$((edge_tested + 1))
    echo "$test_files" | xargs grep -qliE "multiple.*client|different.*key|per.client|isolation" 2>/dev/null && edge_tested=$((edge_tested + 1))
    echo "$test_files" | xargs grep -qliE "burst|rapid|flood|many" 2>/dev/null && edge_tested=$((edge_tested + 1))
  fi
  [[ $edge_tested -ge 1 ]] && score=$((score + 10))
  [[ $edge_tested -ge 2 ]] && score=$((score + 10))
  [[ $edge_tested -ge 3 ]] && score=$((score + 10))

  # Test count: >5 (5 pts), >10 (5 pts), >15 (additional 5 pts)
  local case_count=0
  if [[ -n "$test_files" ]]; then
    case_count=$(echo "$test_files" | xargs grep -cE "it\(|test\(|describe\(|func Test|def test_" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}') || case_count=0
  fi
  [[ $case_count -gt 5 ]] && score=$((score + 5))
  [[ $case_count -gt 10 ]] && score=$((score + 5))
  [[ $case_count -gt 15 ]] && score=$((score + 5))

  # HARDER: Tests include time-related testing (10 pts)
  # Check for setTimeout mocking, Date.now mocking, fake timers, window reset tests, useFakeTimers
  local has_time_tests=0
  if [[ -n "$test_files" ]]; then
    # Check for fake timers / time mocking
    echo "$test_files" | xargs grep -qliE "useFakeTimers|fakeTimers|sinon.*clock|jest.*timer|advanceTimersByTime|tick\(|mockDate|Date\.now|setTimeout|setInterval" 2>/dev/null && has_time_tests=$((has_time_tests + 1))
    # Check for window/reset-related time tests
    echo "$test_files" | xargs grep -qliE "window.*reset|reset.*window|expire|after.*window|wait.*reset|time.*pass|elapsed" 2>/dev/null && has_time_tests=$((has_time_tests + 1))
  fi
  [[ $has_time_tests -ge 1 ]] && score=$((score + 5))
  [[ $has_time_tests -ge 2 ]] && score=$((score + 5))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  local score=0

  local all_src
  all_src=$(find "$ws" -maxdepth 4 \( -name "*.js" -o -name "*.ts" -o -name "*.py" -o -name "*.go" \) ! -path "*/node_modules/*" ! -name "*.test.*" ! -name "*.spec.*" ! -name "*_test.*" 2>/dev/null)

  # Has sensible defaults
  if echo "$all_src" | xargs grep -qliE "default|DEFAULT|= 100|= 60|= 1000" 2>/dev/null; then
    score=$((score + 10))
  fi

  # Has time window management
  if echo "$all_src" | xargs grep -qliE "Date\.now|time\.Now|time\(\)|datetime|window|interval" 2>/dev/null; then
    score=$((score + 10))
  fi

  # Has error handling / input validation
  if echo "$all_src" | xargs grep -qliE "throw|Error|raise|panic|if.*<.*0|invalid|IllegalArgument" 2>/dev/null; then
    score=$((score + 10))
  fi

  # Handles concurrent/multiple clients (key-based or IP-based)
  if echo "$all_src" | xargs grep -qliE "key|client|ip|identifier|Map|dict|map\[" 2>/dev/null; then
    score=$((score + 10))
  fi

  # TypeScript or type annotations used
  local has_types=false
  if find "$ws" -maxdepth 4 -name "*.ts" ! -path "*/node_modules/*" 2>/dev/null | grep -q .; then
    has_types=true
  elif echo "$all_src" | xargs grep -qlE ":\s*(number|string|boolean|void|interface|type )" 2>/dev/null; then
    has_types=true
  fi
  $has_types && score=$((score + 10))

  # Clean code: no console.log in source
  local console_in_src=0
  if [[ -n "$all_src" ]]; then
    console_in_src=$(echo "$all_src" | xargs grep -c "console.log" 2>/dev/null | awk -F: '{s+=$2} END {print s+0}') || console_in_src=0
  fi
  [[ $console_in_src -le 1 ]] && score=$((score + 5))

  # Has cleanup mechanism (memory doesn't grow unbounded) (8 pts for code presence)
  if echo "$all_src" | xargs grep -qliE "cleanup|clear|prune|gc|expire|evict|delete.*old|setTimeout.*clean|setInterval.*clean" 2>/dev/null; then
    score=$((score + 8))
  fi

  # HARDER: Memory bounded — after creating 10000 unique client keys, memory should
  # not grow unboundedly. Verify cleanup actually works by checking map/store size. (10 pts)
  if [[ -f "$ws/package.json" ]]; then
    local mem_test
    local _mem_script
    _mem_script=$(mktemp /tmp/rubric_mem_XXXXXX.js)
    cat > "$_mem_script" <<'MEMJS'
let mod;
try {
  for (const p of ['./src/index','./src/rate-limiter','./src/rateLimiter','./index','./src','./dist/index']) {
    try { mod = require(p); break; } catch(e) {}
  }
  if (!mod) { console.log('NO_IMPORT'); process.exit(); }
  const cfg = {maxRequests:5,limit:5,windowMs:200,window:200,tokens:5,interval:200,windowSize:200,capacity:5,max:5,rate:5,points:5,duration:0.2,cleanupIntervalMs:300,cleanupInterval:300};
  let limiter = null;
  const factoryFn = (typeof mod === 'object') ? (mod.createLimiter || mod.createRateLimiter || mod.create) : null;
  if (typeof factoryFn === 'function') {
    for (const algo of ['fixed-window','fixedWindow','sliding-window','token-bucket',undefined]) {
      try { limiter = factoryFn({...cfg,algorithm:algo,type:algo}); if(limiter) break; } catch(e) {}
      try { limiter = factoryFn(algo, cfg); if(limiter) break; } catch(e) {}
    }
  }
  if (!limiter) {
    let Cls = typeof mod === 'function' ? mod : null;
    if (!Cls && typeof mod === 'object') {
      for (const k of ['RateLimiter','default','FixedWindowLimiter','SlidingWindowLimiter','TokenBucketLimiter','FixedWindowRateLimiter','SlidingWindowRateLimiter','TokenBucketRateLimiter','Limiter','RateLimit']) {
        if (typeof mod[k] === 'function') { Cls = mod[k]; break; }
      }
    }
    if (Cls) { try { limiter = new Cls(cfg); } catch(e) {} }
  }
  if (!limiter) { console.log('NO_LIMITER'); process.exit(); }
  const check = (key) => {
    try {
      return limiter.isAllowed ? limiter.isAllowed(key) :
             limiter.allow ? limiter.allow(key) :
             limiter.check ? limiter.check(key) :
             limiter.consume ? limiter.consume(key) :
             limiter.tryConsume ? limiter.tryConsume(key) : null;
    } catch(e) { return null; }
  };
  const baseline = process.memoryUsage().heapUsed;
  for (let i = 0; i < 1000; i++) { check('client-mem-' + i); }
  const afterBulk = process.memoryUsage().heapUsed;
  setTimeout(() => {
    for (let i = 0; i < 10; i++) { check('trigger-cleanup-' + i); }
    let storeSize = -1;
    try {
      for (const k of ['store','clients','map','windows','buckets','_store','requests','_clients','_windows','_map','_buckets','entries','_entries','records','_records']) {
        const obj = limiter[k];
        if (!obj) continue;
        if (obj.size !== undefined) { storeSize = obj.size; break; }
        if (typeof obj === 'object') { storeSize = Object.keys(obj).length; break; }
      }
    } catch(e) {}
    if (storeSize >= 0 && storeSize < 500) {
      console.log('PASS:size=' + storeSize);
    } else if (storeSize >= 500) {
      console.log('FAIL:no_cleanup:size=' + storeSize);
    } else {
      const afterCleanup = process.memoryUsage().heapUsed;
      const grew = afterBulk - baseline;
      const current = afterCleanup - baseline;
      if (current < grew * 0.8) {
        console.log('PASS:mem_reduced');
      } else {
        console.log('FAIL:no_observable_cleanup');
      }
    }
    process.exit();
  }, 1000);
} catch(e) {
  console.log('ERROR:' + e.message);
}
MEMJS
    mem_test=$(cd "$ws" && timeout 8 node < "$_mem_script" 2>&1) || true
    rm -f "$_mem_script"
    [[ "$mem_test" == *"PASS"* ]] && score=$((score + 10))
  fi

  # Uses modern JS/TS features (const/let, arrow functions, classes)
  if echo "$all_src" | xargs grep -qE "class |=>" 2>/dev/null; then
    score=$((score + 5))
  fi

  # Has JSDoc or proper documentation comments
  if echo "$all_src" | xargs grep -qlE "/\*\*|///|\"\"\"" 2>/dev/null; then
    score=$((score + 10))
  fi

  # Implements retry-after or remaining count info
  if echo "$all_src" | xargs grep -qliE "retry.after|retryAfter|remaining|reset.*time|resetAt|X-RateLimit" 2>/dev/null; then
    score=$((score + 10))
  fi

  # Separation of concerns (algorithm in separate file from API/middleware)
  local src_file_count
  src_file_count=$(echo "$all_src" | grep -c . 2>/dev/null) || src_file_count=0
  [[ $src_file_count -ge 3 ]] && score=$((score + 5))

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}
