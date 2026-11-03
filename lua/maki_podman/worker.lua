-- Runs only inside the chat container. Dependencies: Lua 5.4, LuaFileSystem,
-- ripgrep and GNU coreutils (realpath/stat). Server mode also needs LuaSocket.
-- Requests have an eight-hex-digit length and newline prefix; replies are NDJSON.
local lfs = require("lfs")
local MAX_BYTES = 64 * 1024 * 1024
local CHUNK = 48 * 1024
local FRAME_BYTES = 128 * 1024
local PROTOCOL = 1
local connection, response_id, send_failed
local handles, temporary = {}, {}

local function track(handle)
  if handle then handles[#handles + 1] = handle end
  return handle
end
local function open_file(path, mode)
  local file, err = io.open(path, mode)
  return track(file), err
end
local function open_pipe(command)
  local pipe, err = io.popen(command, "r")
  return track(pipe), err
end
local function cleanup()
  for i = #handles, 1, -1 do pcall(function() handles[i]:close() end) end
  for _, path in ipairs(temporary) do os.remove(path) end
  handles, temporary = {}, {}
end
local NULL = setmetatable({}, { __json_null = true })
local ARRAY = { __json_array = true }
local function array(t) return setmetatable(t or {}, ARRAY) end

local function valid_utf8(s)
  return utf8.len(s) ~= nil
end

local function json_string(s)
  if not valid_utf8(s) then error("non-utf8 JSON string", 0) end
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    local escapes = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
    return escapes[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function json_encode(v)
  if v == NULL or v == nil then return "null" end
  local kind = type(v)
  if kind == "string" then return json_string(v) end
  if kind == "boolean" then return v and "true" or "false" end
  if kind == "number" then
    if v ~= v or v == math.huge or v == -math.huge then error("nonfinite JSON number", 0) end
    return tostring(v)
  end
  if kind ~= "table" then error("unsupported JSON value", 0) end
  local out = {}
  if getmetatable(v) == ARRAY or #v > 0 then
    for i = 1, #v do out[#out + 1] = json_encode(v[i]) end
    return "[" .. table.concat(out, ",") .. "]"
  end
  for k, value in pairs(v) do out[#out + 1] = json_string(k) .. ":" .. json_encode(value) end
  table.sort(out)
  return "{" .. table.concat(out, ",") .. "}"
end

local function json_decode(s)
  local p, n = 1, #s
  local parse
  local function fail() error("invalid JSON at byte " .. p, 0) end
  local function white()
    local _, stop = s:find("^[ \t\r\n]*", p)
    p = (stop or p - 1) + 1
  end
  local function str()
    p = p + 1
    local out, first = {}, p
    while p <= n do
      local b = s:byte(p)
      if b == 34 then
        out[#out + 1] = s:sub(first, p - 1)
        p = p + 1
        local text = table.concat(out)
        if not valid_utf8(text) then fail() end
        return text
      elseif b == 92 then
        out[#out + 1] = s:sub(first, p - 1)
        p = p + 1
        local c = s:sub(p, p)
        local escapes = { ['"']='"', ['\\']='\\', ['/']='/', b='\b', f='\f', n='\n', r='\r', t='\t' }
        if escapes[c] then
          out[#out + 1] = escapes[c]
          p = p + 1
        elseif c == "u" then
          local h = s:sub(p + 1, p + 4)
          if #h ~= 4 or h:find("[^%x]") then fail() end
          local cp = tonumber(h, 16)
          p = p + 5
          if cp >= 0xd800 and cp <= 0xdbff then
            if s:sub(p, p + 1) ~= "\\u" then fail() end
            local lowhex = s:sub(p + 2, p + 5)
            if #lowhex ~= 4 or lowhex:find("[^%x]") then fail() end
            local low = tonumber(lowhex, 16)
            if low < 0xdc00 or low > 0xdfff then fail() end
            cp = 0x10000 + (cp - 0xd800) * 0x400 + low - 0xdc00
            p = p + 6
          elseif cp >= 0xdc00 and cp <= 0xdfff then
            fail()
          end
          out[#out + 1] = utf8.char(cp)
        else fail() end
        first = p
      elseif b < 32 then fail()
      else p = p + 1 end
    end
    fail()
  end
  function parse(depth)
    if depth > 100 then error("JSON nesting is too deep", 0) end
    white()
    local c = s:sub(p, p)
    if c == '"' then return str() end
    if c == "{" or c == "[" then
      local obj = c == "{" and {} or array()
      local close = c == "{" and "}" or "]"
      p = p + 1
      white()
      if s:sub(p, p) == close then p = p + 1; return obj end
      while true do
        local k
        if c == "{" then
          white()
          if s:sub(p, p) ~= '"' then fail() end
          k = str()
          white()
          if s:sub(p, p) ~= ":" then fail() end
          p = p + 1
        else k = #obj + 1 end
        obj[k] = parse(depth + 1)
        white()
        local sep = s:sub(p, p)
        p = p + 1
        if sep == close then return obj end
        if sep ~= "," then fail() end
      end
    end
    for word, value in pairs({ ["true"]=true, ["false"]=false, ["null"]=NULL }) do
      if s:sub(p, p + #word - 1) == word then p = p + #word; return value end
    end
    local first = p
    if c == "-" then p = p + 1 end
    if s:sub(p, p) == "0" then p = p + 1
    elseif s:sub(p, p):match("[1-9]") then
      repeat p = p + 1 until not s:sub(p, p):match("%d")
    else fail() end
    if s:sub(p, p) == "." then
      p = p + 1
      if not s:sub(p, p):match("%d") then fail() end
      repeat p = p + 1 until not s:sub(p, p):match("%d")
    end
    if s:sub(p, p):match("[eE]") then
      p = p + 1
      if s:sub(p, p):match("[+-]") then p = p + 1 end
      if not s:sub(p, p):match("%d") then fail() end
      repeat p = p + 1 until not s:sub(p, p):match("%d")
    end
    local number = tonumber(s:sub(first, p - 1))
    if not number or number == math.huge or number == -math.huge then fail() end
    return number
  end
  local value = parse(0)
  white()
  if p <= n then fail() end
  return value
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUES = {}
for i = 1, #B64 do B64_VALUES[B64:byte(i)] = i - 1 end
local function base64_encode(s)
  local out = {}
  for p = 1, #s, 3 do
    local a, b, c = s:byte(p, p + 2)
    local v = a * 65536 + (b or 0) * 256 + (c or 0)
    out[#out + 1] = B64:sub((v >> 18) + 1, (v >> 18) + 1)
      .. B64:sub(((v >> 12) & 63) + 1, ((v >> 12) & 63) + 1)
      .. (b and B64:sub(((v >> 6) & 63) + 1, ((v >> 6) & 63) + 1) or "=")
      .. (c and B64:sub((v & 63) + 1, (v & 63) + 1) or "=")
  end
  return table.concat(out)
end
local function decode_base64_block(s)
  if type(s) ~= "string" or #s % 4 ~= 0 or s:find("[^%w+/=]") then error("invalid base64 payload", 0) end
  local out = {}
  for p = 1, #s, 4 do
    local a,b,c,d = s:byte(p,p + 3)
    local va,vb,vc,vd = B64_VALUES[a],B64_VALUES[b],B64_VALUES[c],B64_VALUES[d]
    if not va or not vb or (not vc and c ~= 61) or (not vd and d ~= 61)
      or (c == 61 and d ~= 61) or ((c == 61 or d == 61) and p + 3 ~= #s)
      or (c == 61 and vb % 16 ~= 0) or (d == 61 and vc and vc % 4 ~= 0) then
      error("invalid base64 payload", 0)
    end
    local v = va * 262144 + vb * 4096 + (vc or 0) * 64 + (vd or 0)
    out[#out + 1] = string.char((v >> 16) & 255)
      .. (c ~= 61 and string.char((v >> 8) & 255) or "")
      .. (d ~= 61 and string.char(v & 255) or "")
  end
  return table.concat(out)
end

local function base64_decode(s)
  if type(s) ~= "string" or #s > math.ceil(MAX_BYTES / 3) * 4 then
    error("base64 payload exceeds the 64 MiB transfer limit",0)
  end
  local padding = s:find("=",1,true)
  if padding and (padding < #s - 1 or s:sub(padding):find("[^=]")) then
    error("invalid base64 payload",0)
  end
  local out = {}
  for start = 1, #s, 64 * 1024 do
    out[#out + 1] = decode_base64_block(s:sub(start,start + 64 * 1024 - 1))
  end
  return table.concat(out)
end

local function emit(value)
  if response_id ~= nil then value.id = response_id end
  local line = json_encode(value) .. "\n"
  if #line > FRAME_BYTES then error("filesystem response frame exceeds the 128 KiB limit", 0) end
  if connection then
    local sent, err = connection:send(line)
    if sent ~= #line then
      send_failed = true
      error("filesystem connection failed: " .. tostring(err or "short write"), 0)
    end
  else
    io.write(line)
  end
end
local function chunks(s, key)
  for start = 1, #s, CHUNK do emit({ [key or "chunk"] = base64_encode(s:sub(start, start + CHUNK - 1)) }) end
end
local function emit_entry(value)
  local encoded = json_encode(value)
  if #encoded <= CHUNK then emit({entry=value})
  else chunks(encoded,"entry_chunk"); emit({entry_end=true}) end
end
local function checked(v, err)
  if not v then error(tostring(err or "filesystem operation failed"), 0) end
  return v
end
local function path_string(path)
  if type(path) ~= "string" or path:find("\0", 1, true) or not valid_utf8(path) then
    error("path must be a UTF-8 string without NUL bytes", 0)
  end
  return path
end
local function quote(s)
  if type(s) ~= "string" or s:find("\0", 1, true) then error("invalid command argument", 0) end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end
local function abspath(path)
  path_string(path)
  local home = os.getenv("HOME")
  if path == "~" or path:sub(1,2) == "~/" then
    if not home or home:sub(1,1) ~= "/" then error("container HOME is unavailable", 0) end
    path = home .. path:sub(2)
  end
  if path:sub(1,1) ~= "/" then path = checked(lfs.currentdir()) .. "/" .. path end
  return path
end
local function command(args)
  local out = {}
  for _,a in ipairs(args) do out[#out + 1] = quote(tostring(a)) end
  return table.concat(out, " ")
end
local function capture(args)
  local pipe = checked(open_pipe(command(args) .. " 2>/dev/null"))
  local result = pipe:read(MAX_BYTES + 1)
  local ok,_,status = pipe:close()
  if result and #result > MAX_BYTES then error("command output exceeds the 64 MiB limit", 0) end
  if not ok then return nil, "container command failed (exit " .. tostring(status) .. "): " .. tostring(args[1]) end
  return result or ""
end
local function canonical(path)
  local value = checked(capture({ "realpath", "-m", "-z", "--", abspath(path) }))
  return value:gsub("\0$", "")
end
local function fingerprint(path)
  local attr = lfs.attributes(path)
  if not attr then return nil end
  return checked(capture({ "stat", "--dereference", "--printf", "%d:%i:%s:%f:%y:%z", "--", path }))
end
local function identity(path)
  local stamp = fingerprint(path)
  return { canonical = canonical(path), fingerprint = stamp or NULL, exists = stamp ~= nil }
end
local function unchanged(path, before)
  local after = fingerprint(path)
  if before ~= after then error("file changed while being read; retry the read", 0) end
  return { canonical = canonical(path), fingerprint = after or NULL, exists = after ~= nil }
end
local function metadata(path)
  path = abspath(path)
  local attr,err,errno = lfs.attributes(path)
  if not attr then
    if errno == 2 or errno == 20 then return NULL end
    error(err or "cannot read file metadata", 0)
  end
  local stamp = fingerprint(path)
  local fraction = stamp and stamp:match("%d%d:%d%d:%d%d%.(%d+) [+-]%d%d%d%d:")
  return { size = attr.size, is_file = attr.mode == "file", is_dir = attr.mode == "directory",
    mtime = attr.modification + (tonumber(fraction and ("0." .. fraction)) or 0),
    canonical = canonical(path), fingerprint = stamp, exists = true }
end
local function integer(v, default, min, name)
  if v == nil or v == NULL then return default end
  if type(v) ~= "number" or v % 1 ~= 0 or v < min then error((name or "option") .. " must be an integer >= " .. min, 0) end
  return v
end
local function regular(path)
  local a = checked(lfs.attributes(path))
  if a.mode ~= "file" then error("path is not a regular file: " .. path, 0) end
  return a
end
local function ensure_utf8(text)
  if not valid_utf8(text) then error("non-utf8 content; use read_bytes", 0) end
  return text
end
local function utf8_cut(text, limit, lossy)
  if lossy then
    local parts, p = {}, 1
    while p <= #text do
      local len, bad = utf8.len(text, p)
      if len then parts[#parts + 1] = text:sub(p); break end
      parts[#parts + 1] = text:sub(p, bad - 1)
      parts[#parts + 1] = "\239\191\189"
      p = bad + 1
      while p <= #text and text:byte(p) >= 0x80 and text:byte(p) <= 0xbf do p = p + 1 end
    end
    text = table.concat(parts)
  end
  if limit and limit > 0 and #text > limit then
    local stop = limit
    while stop > 0 and text:byte(stop + 1) >= 0x80 and text:byte(stop + 1) <= 0xbf do stop = stop - 1 end
    text = text:sub(1,stop) .. "..."
  end
  return ensure_utf8(text)
end

-- A bounded scanner: skipped portions and oversized line tails never build
-- strings proportional to the size of the input file.
local function scanner(file)
  local pending, pos, ended = "", 1, false
  return function(keep)
    if ended then return nil end
    local pieces, stored, length, last, found = {}, 0, 0, nil, false
    while true do
      if pos > #pending then
        pending = file:read(64 * 1024)
        pos = 1
        if not pending then ended = true; break end
      end
      local newline = pending:find("\n", pos, true)
      local stop = newline and newline - 1 or #pending
      local count = stop - pos + 1
      if count > 0 then
        found = true
        length = length + count
        last = pending:byte(stop)
        if keep and stored < keep then
          local take = math.min(count, keep - stored)
          pieces[#pieces + 1] = pending:sub(pos, pos + take - 1)
          stored = stored + take
        end
      end
      pos = stop + (newline and 2 or 1)
      if newline then found = true; break end
    end
    if not found and ended then return nil end
    return table.concat(pieces), length, last, not ended
  end
end
local function read_lines(path, opts)
  path = abspath(path)
  regular(path)
  local before = fingerprint(path)
  local file = checked(open_file(path,"rb"))
  local nextline = scanner(file)
  local offset = math.max(integer(opts.offset,1,0,"offset"),1)
  local limit = integer(opts.limit,0,0,"limit")
  local cap = integer(opts.max_line_bytes,0,0,"max_line_bytes")
  local count, shown, cost = 0, 0, 0
  while true do
    local show = count + 1 >= offset and (limit == 0 or shown < limit)
    if opts.count == false and count + 1 >= offset and not show then break end
    local line, length, last = nextline(show and math.min(cap > 0 and cap + 2 or MAX_BYTES + 2, MAX_BYTES + 2) or nil)
    if not line then break end
    count = count + 1
    if show then
      if last == 13 then length = length - 1 end
      if #line > length then line = line:sub(1,length) end
      if cap > 0 and length > cap then line = utf8_cut(line, cap)
      elseif length > MAX_BYTES then file:close(); error("file exceeds the 67108864-byte read limit",0)
      else line = ensure_utf8(line) end
      shown, cost = shown + 1, cost + #line + 24
      if cost > MAX_BYTES then file:close(); error("file exceeds the 67108864-byte read limit",0) end
      chunks(line, "line_chunk")
      emit({ line_end = true })
    end
  end
  file:close()
  local result = unchanged(path,before)
  if opts.count ~= false then result.total = count end
  return result
end
local function read_all(path, opts, binary)
  path = abspath(path)
  local attr = regular(path)
  local before = fingerprint(path)
  local file = checked(open_file(path,"rb"))
  local result
  if binary then
    local offset = integer(opts.offset,0,-MAX_BYTES*1024,"offset")
    local len = integer(opts.len,MAX_BYTES+1,0,"len")
    local start = offset < 0 and math.max(0,attr.size + offset) or offset
    checked(file:seek("set",start))
    result = file:read(math.min(len,MAX_BYTES + 1)) or ""
  elseif opts.offset ~= nil or opts.limit ~= nil then
    local offset = integer(opts.offset,1,-MAX_BYTES*1024,"offset")
    local limit = integer(opts.limit,0,0,"limit")
    if offset < 0 then
      local count = 0
      local scan = scanner(file)
      while scan(nil) do count = count + 1 end
      offset = math.max(1,count + offset + 1)
      checked(file:seek("set",0))
    end
    local scan, lines, count, size = scanner(file), {}, 0, 0
    while true do
      local keep = count + 1 >= math.max(offset,1)
      local line,length,_,has_newline = scan(keep and MAX_BYTES + 1 or nil)
      if not line then break end
      count = count + 1
      if keep then
        size = size + length + (has_newline and 1 or 0)
        if size > MAX_BYTES then file:close(); error("file exceeds the 67108864-byte read limit",0) end
        lines[#lines + 1] = line .. (has_newline and "\n" or "")
        if limit > 0 and #lines >= limit then break end
      end
    end
    result = table.concat(lines)
  else
    if attr.size > MAX_BYTES then file:close(); error("file exceeds the 67108864-byte read limit",0) end
    result = file:read(MAX_BYTES+1) or ""
  end
  file:close()
  if #result > MAX_BYTES then error("file exceeds the 67108864-byte read limit",0) end
  if not binary then ensure_utf8(result) end
  local info = unchanged(path,before)
  chunks(result)
  return info
end
local function mkdir(path, parents)
  path = abspath(path)
  if parents then
    local prefix = "/"
    for component in path:gmatch("[^/]+") do
      prefix = prefix .. component .. "/"
      local a = lfs.attributes(prefix)
      if a then
        if a.mode ~= "directory" then error("not a directory: " .. prefix,0) end
      else checked(lfs.mkdir(prefix)) end
    end
  else checked(lfs.mkdir(path)) end
  return true
end
local function check_expected(path, req)
  if req.expected then
    local now = identity(path)
    if now.canonical ~= req.expected.canonical or now.fingerprint ~= (req.expected.fingerprint or NULL)
      or now.exists ~= req.expected.exists then
      error("file changed since last read; re-read using read before editing",0)
    end
  end
  if req.expected_fingerprint ~= nil then
    local expected = req.expected_fingerprint == NULL and nil or req.expected_fingerprint
    if fingerprint(path) ~= expected then error("file changed since last read; re-read using read before editing",0) end
  end
  if req.expected_canonical ~= nil and canonical(path) ~= req.expected_canonical then
    error("file target changed; re-read using read before editing",0)
  end
end
local function write_file(path, req, append)
  path = abspath(path)
  check_expected(path,req)
  if type(req.content_b64) ~= "string" then error("write requires content_b64",0) end
  local data = base64_decode(req.content_b64)
  if #data > MAX_BYTES then error("write exceeds the 67108864-byte transfer limit",0) end
  local a = lfs.attributes(path)
  if a and a.mode ~= "file" then error("path is not a regular file: " .. path,0) end
  local file = checked(open_file(path,append and "ab" or "wb"))
  local ok,err = file:write(data)
  local closed,close_err = file:close()
  checked(ok,err)
  checked(closed,close_err)
  return identity(path)
end
local function remove(path,req)
  path = abspath(path)
  check_expected(path,req)
  local opts = req.opts or {}
  if opts.recursive then error("recursive removal is not supported by this adapter",0) end
  local attr,err,errno = lfs.symlinkattributes(path)
  if not attr then
    if opts.force and errno == 2 then return true end
    error(err or "path does not exist",0)
  end
  if attr.mode == "directory" then checked(lfs.rmdir(path))
  elseif attr.mode == "file" or attr.mode == "link" then checked(os.remove(path))
  else error("refusing to remove a special file: " .. path,0) end
  return true
end
local function dir(path,opts)
  path = abspath(path)
  local a = checked(lfs.attributes(path))
  if a.mode ~= "directory" then error("dir: not a directory: " .. path,0) end
  local visited, depth, entries, cost = {}, integer(opts.depth,1,0,"depth"), 0, 0
  local function walk(current,prefix,level)
    local iter,state = lfs.dir(current)
    track(state)
    if not iter then return end
    for name in iter,state do
      if name ~= "." and name ~= ".." and valid_utf8(name) then
        local child = current .. "/" .. name
        local attrs = lfs.attributes(child)
        local typ = attrs and attrs.mode or (lfs.symlinkattributes(child) or {}).mode
        typ = ({ file="file",directory="directory",link="link" })[typ] or "unknown"
        cost = cost + #prefix + #name + 24
        if cost > MAX_BYTES then error("directory result exceeds the 64 MiB limit",0) end
        emit_entry(array({prefix .. name,typ}))
        entries = entries + 1
        if typ == "directory" and level < depth then
          local key = canonical(child)
          if not visited[key] then visited[key] = true; walk(child,prefix .. name .. "/",level + 1) end
        end
      end
    end
  end
  walk(path,"",1)
  return { count = entries }
end
local function rg_args(path,opts,files)
  local args = {"rg","--no-config","--hidden","--glob","!.git"}
  if files then args[#args + 1] = "--files"; args[#args + 1] = "--null"
  else args[#args + 1] = "--json"; args[#args + 1] = "--threads"; args[#args + 1] = "1" end
  if opts.gitignore == false then args[#args + 1] = "--no-ignore" end
  if opts.sort == "mtime" or not files then args[#args + 1] = "--sortr"; args[#args + 1] = "modified" end
  return args
end
local function open_rg(args, request_path)
  local errors = request_path .. ".stderr"
  temporary[#temporary + 1] = errors
  local pipe = checked(open_pipe(command(args) .. " 2>" .. quote(errors)))
  return pipe,function(allow_matchless)
    local ok,_,code = pipe:close()
    local file = open_file(errors,"rb")
    local msg = file and file:read(8192) or ""
    if file then file:close() end
    os.remove(errors)
    if not ok and not (allow_matchless and code == 1) then
      error("ripgrep failed (exit " .. tostring(code) .. "): " .. (msg or ""),0)
    end
  end
end
local function glob(path,pattern,opts,request_path)
  local args = rg_args(path,opts,true)
  local patterns = type(pattern) == "table" and pattern or {pattern}
  for _,p in ipairs(patterns) do args[#args + 1] = "--glob"; args[#args + 1] = path_string(p) end
  args[#args + 1] = "--"; args[#args + 1] = abspath(path)
  local pipe,finish = open_rg(args,request_path)
  local carry,count,cost = "",0,0
  local limit = integer(opts.limit,0,0,"limit")
  while true do
    local bytes = pipe:read(CHUNK)
    if not bytes then break end
    carry = carry .. bytes
    local start = 1
    while true do
      local stop = carry:find("\0",start,true)
      if not stop then break end
      local value = carry:sub(start,stop - 1)
      if valid_utf8(value) and (limit == 0 or count < limit) then
        count,cost = count + 1,cost + #value + 24
        if cost > MAX_BYTES then pipe:close(); error("glob result exceeds the 64 MiB limit",0) end
        emit_entry(value)
      end
      start = stop + 1
    end
    carry = carry:sub(start)
    if #carry > 1024 * 1024 then pipe:close(); error("glob path exceeds the 1 MiB limit",0) end
  end
  finish(true)
  return {count=count}
end
local function grep(path,pattern,opts,request_path)
  path = abspath(path)
  path_string(pattern)
  local before = integer(opts.context_before,0,0,"context_before")
  local after = integer(opts.context_after,0,0,"context_after")
  local limit = integer(opts.limit,100,0,"limit")
  local cap = integer(opts.max_line_bytes,500,0,"max_line_bytes")
  local args = rg_args(path,opts,false)
  if opts.include then args[#args + 1] = "--glob"; args[#args + 1] = path_string(opts.include) end
  if pattern:find("\\n",1,true) or pattern:find("(?s)",1,true) or pattern:find("(?m)",1,true) then args[#args + 1] = "--multiline" end
  for _,a in ipairs({"--before-context",before,"--after-context",after,"--regexp",pattern,"--",path}) do args[#args + 1] = a end
  local pipe,finish = open_rg(args,request_path)
  local nextline = scanner(pipe)
  local entries,current,group,last_nr,cost = {},nil,nil,nil,0
  local context = before > 0 or after > 0
  local function field(v)
    if not v or v == NULL then return nil end
    return v.text or (v.bytes and base64_decode(v.bytes))
  end
  while true do
    local line,length = nextline(MAX_BYTES + 1)
    if not line then break end
    if length > MAX_BYTES then pipe:close(); error("ripgrep JSON record exceeds the 64 MiB limit",0) end
    local event = json_decode(line)
    local data = event.data
    if event.type == "begin" then
      local name = field(data.path)
      current = name and valid_utf8(name) and {path=name,groups=array(),fingerprint=fingerprint(name) or NULL} or nil
      group,last_nr = nil,nil
    elseif current and (event.type == "match" or event.type == "context") then
      local is_match = event.type == "match"
      local nr = data.line_number
      local raw = field(data.lines) or ""
      if not context or not last_nr or nr > last_nr + 1 then
        if #current.groups < limit then
          group = {lines=array()}
          current.groups[#current.groups + 1] = group
        else group = nil end
      end
      local start = 1
      while start <= #raw do
        local stop = raw:find("\n",start,true)
        local text = raw:sub(start,(stop or #raw + 1) - 1):gsub("\r$","")
        if group then
          text = utf8_cut(text,cap,true)
          cost = cost + #text + 64
          if cost > MAX_BYTES then pipe:close(); error("grep result exceeds the 64 MiB limit",0) end
          group.lines[#group.lines + 1] = {line_nr=nr,text=text,is_match=is_match}
        end
        last_nr = nr
        nr = nr + 1
        if not stop then break end
        start = stop + 1
      end
    elseif event.type == "end" and current then
      if #current.groups > 0 then
        if (fingerprint(current.path) or NULL) ~= current.fingerprint then
          pipe:close(); error("file changed while being searched; retry the search",0)
        end
        local stamp = capture({"stat","--dereference","--printf","%y","--",current.path})
        current.stamp = stamp or ""
        entries[#entries + 1] = current
      end
      current,group,last_nr = nil,nil,nil
    end
  end
  finish(true)
  table.sort(entries,function(a,b) return a.stamp == b.stamp and a.path < b.path or a.stamp > b.stamp end)
  local total,count = 0,0
  for _,entry in ipairs(entries) do
    local remaining = limit - total
    while #entry.groups > remaining do entry.groups[#entry.groups] = nil end
    if #entry.groups > 0 then
      entry.stamp = nil
      -- Search receipts track the exact container file, never a host path.
      entry.canonical,entry.fingerprint = canonical(entry.path),fingerprint(entry.path) or NULL
      emit_entry(entry)
      count,total = count + 1,total + #entry.groups
    end
  end
  return {count=count}
end

local function dispatch(req, request_path)
  if type(req) ~= "table" or req == NULL or getmetatable(req) == ARRAY then
    error("request must be an object",0)
  end
  local opts,op = req.opts or {},req.op
  if op == "context" then return {cwd=checked(lfs.currentdir()),home=os.getenv("HOME") or NULL} end
  if op == "abspath" then return abspath(req.path) end
  if op == "canonical" or op == "version" then return identity(abspath(req.path)) end
  if op == "metadata" then return metadata(req.path) end
  if op == "read" then return read_all(req.path,opts,false) end
  if op == "read_bytes" then return read_all(req.path,opts,true) end
  if op == "read_lines" then return read_lines(req.path,opts) end
  if op == "write" or op == "append" then return write_file(req.path,req,op == "append") end
  if op == "mkdir" then return mkdir(req.path,opts.parents) end
  if op == "rm" then return remove(req.path,req) end
  if op == "dir" then return dir(req.path,opts) end
  if op == "glob" then return glob(req.path or ".",req.pattern,opts,request_path) end
  if op == "grep" then return grep(req.path or ".",req.pattern,opts,request_path) end
  error("unknown filesystem operation: " .. tostring(op),0)
end

local function respond(req, request_path)
  send_failed = false
  local ok, result = pcall(dispatch, req, request_path)
  cleanup()
  if send_failed then return nil, tostring(result) end
  local sent, err = pcall(emit, ok and {ok=true,value=result} or {ok=false,error=tostring(result)})
  if not sent then return nil, tostring(err) end
  return true
end

local function receive_request(client, limit, deadline, clock)
  local function receive(count)
    if deadline then
      local remaining = deadline - clock()
      if remaining <= 0 then return nil, "authentication timed out" end
      client:settimeout(remaining)
    end
    return client:receive(count)
  end
  local header, err = receive(9)
  if not header then return nil, err end
  if not header:match("^%x%x%x%x%x%x%x%x\n$") then return nil, "invalid request length header" end
  local count = tonumber(header:sub(1,8),16)
  if count == 0 or count > limit then return nil, "request exceeds the allowed size" end
  local encoded
  encoded, err = receive(count)
  if not encoded then return nil, err end
  local ok, req = pcall(json_decode, encoded)
  if not ok then return nil, tostring(req) end
  if type(req) ~= "table" or req == NULL or getmetatable(req) == ARRAY then
    return nil, "request must be an object"
  end
  return req
end

local function authentic(token, supplied)
  if type(supplied) ~= "string" then return false end
  local different = #token ~ #supplied
  for i = 1, #token do different = different | (token:byte(i) ~ (supplied:byte(i) or 0)) end
  return different == 0
end

local function serve(port, token_path)
  local socket = require("socket")
  port = tonumber(port)
  if not port or port % 1 ~= 0 or port < 1 or port > 65535 then error("invalid worker port",0) end
  local file = checked(io.open(path_string(token_path), "rb"))
  local token = file:read(256)
  file:close()
  token = (token or ""):gsub("\n$", "")
  if #token ~= 44 or #base64_decode(token) ~= 32 then error("invalid worker authentication token",0) end
  local listener = checked(socket.bind("0.0.0.0",port,1))
  listener:settimeout(nil)
  io.stdout:write(json_encode({ready=true,protocol=PROTOCOL}), "\n")
  io.stdout:flush()

  while true do
    local client = checked(listener:accept())
    client:setoption("tcp-nodelay",true)
    local auth = receive_request(client,8192,socket.gettime() + 5,socket.gettime)
    if auth and auth.id == 0 and auth.protocol == PROTOCOL and authentic(token,auth.token) then
      listener:close()
      client:settimeout(nil)
      connection, response_id = client, 0
      local ok, err = pcall(function()
        emit({ok=true,protocol=PROTOCOL,context={cwd=checked(lfs.currentdir()),home=os.getenv("HOME") or NULL}})
        local last_id = 0
        while true do
          local req, read_err = receive_request(client,MAX_BYTES * 2)
          if not req then return read_err end
          if type(req.id) ~= "number" or req.id % 1 ~= 0 or req.id <= last_id or req.id > 9007199254740991 then
            return "invalid filesystem request id"
          end
          response_id, last_id = req.id, req.id
          local replied, reply_err = respond(req, token_path .. ".request-" .. tostring(req.id))
          if not replied then return reply_err end
        end
      end)
      cleanup()
      client:close()
      connection, response_id = nil, nil
      if not ok then io.stderr:write("filesystem worker: ",tostring(err),"\n") end
      return
    end
    client:close()
  end
end

if arg[1] == "--serve" then
  serve(arg[2],arg[3])
else
  -- One-shot mode is retained for protocol regression tests and diagnostics.
  local ok, req = pcall(function()
    local request = checked(open_file(arg[1],"rb"))
    local encoded = request:read(MAX_BYTES * 2 + 1)
    request:close()
    if not encoded or #encoded > MAX_BYTES * 2 then error("request exceeds the 128 MiB limit",0) end
    return json_decode(encoded)
  end)
  if ok then respond(req,arg[1])
  else cleanup(); emit({ok=false,error=tostring(req)}) end
end
