#!/bin/env lua
-- Copyright 2023 Mitchell. See LICENSE.
-- Simple Lua language server for developing with Lua and Textadept.

local lfs = require('lfs')
local dir = arg[0]:match('^(.+)[/\\]')
lfs.chdir(dir) -- cd to this directory
local ldoc = string.format('"%s" -L "%s/ldoc.lua"', arg[-2] or 'ldoc', dir)
package.path = string.format('%s/?.lua;%s/?/init.lua;%s', dir, dir, package.path)

local json = require('dkjson')
local pl_dir = require('pl.dir')

local WIN32 = package.path:find('\\')

local log_file = io.open('log', 'w')
local function log(...)
  local args = table.pack(...)
  for i = 1, args.n do log_file:write(tostring(args[i])) end
  log_file:write('\n'):flush()
end

local log_rpc = false

-- Read a request or notification from the LSP client.
-- @return JSON RPC object received
local function read()
  local line = io.read()
  while not line:find('^Content%-Length: %d+') do line = io.read() end
  local len = tonumber(line:match('%d+'))
  -- while #line > 0 do line = io.read() end -- skip other headers
  local data = io.read(len)
  if log_rpc then log('RPC recv: ', data) end
  return json.decode(data)
end

-- Respond to an LSP client request.
-- @param id ID of the client request being responded to.
-- @param result Table object to send.
local function respond(id, result)
  local key = not (result.code and result.message) and 'result' or 'error'
  local message = {jsonrpc = '2.0', id = id, [key] = result}
  local content = json.encode(message)
  if log_rpc then log('RPC send: ', content) end
  io.write(string.format('Content-Length: %d\r\n\r\n%s\r\n', #content + 2, content)):flush()
end

local root, options, client_capabilities, cache, tags, api
local files = {} -- map of open file URIs to their content lines
local handlers = {} -- LSP method and notification handlers

-- Registers function *f* as the handler for the LSP method named *method*.
-- Requests must return either an object to respond with or `json.null`.
-- Notifications must not return anything at all (`nil`).
-- @param method String LSP method name to handle.
-- @param f Method handler function.
local function register(method, f) handlers[method] = f end

-- Converts the given LSP DocumentUri into a valid filename and returns it.
-- @param uri LSP DocumentUri to convert into a filename.
local function tofilename(uri)
  local filename = uri:gsub(not WIN32 and '^file://' or '^file:///', '')
  filename = filename:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  if WIN32 then filename = filename:gsub('/', '\\') end
  return filename
end

-- Converts the given filename into a valid LSP DocumentUri and returns it.
-- @param filename String filename to convert into an LSP DocumentUri.
local function touri(filename)
  return not WIN32 and 'file://' .. filename or 'file:///' .. filename:gsub('\\', '/')
end

-- LSP initialize request.
register('initialize', function(params)
  root = tofilename(params.workspaceFolders and params.workspaceFolders[1].uri or params.rootUri or
    params.rootPath)
  cache = os.tmpname()
  os.remove(cache) -- Linux creates this file
  lfs.mkdir(cache)
  pl_dir.copyfile('tadoc.lua', cache .. '/tadoc.lua')
  log('Initialize: root=', root, ' cache=', cache)
  options = params.initializationOptions
  client_capabilities = params.capabilities
  return {
    capabilities = {
      positionEncoding = 'utf-8', --
      textDocumentSync = {
        openClose = true, change = 1 -- Full
      },
      -- notebookDocumentSync = nil,
      completionProvider = {
        triggerCharacters = {'.', ':'}, --
        allCommitCharacters = {'\t', '(', '{', '.', ':'}
        -- resolveProvider = true,
        -- completionItem = {labelDetailsSupport = true},
      }, --
      hoverProvider = true,
      signatureHelpProvider = {triggerCharacters = {'(', ','}, retriggerCharacters = {','}},
      -- declarationProvider = true,
      definitionProvider = true,
      -- typeDefinitionProvider = true,
      -- implementationProvider = true,
      -- referencesProvider = true,
      -- documentHighlightProvider = true,
      -- documentSymbolProvider = true,
      -- codeActionProvider = {codeActionKinds = {},resolveProvider = true},
      -- codeLensProvider = {resolveProvider = true},
      -- documentLinkProvider = {resolveProvider = true},
      -- colorProvider = true,
      -- documentFormattingProvider = true,
      -- documentRangeFormattingProvider = true,
      -- documentOnTypeFormattingProvider = {},
      -- renameProvider = {prepareProvider = true},
      -- foldingRangeProvider = true,
      -- executeCommandProvider = {},
      -- selectionRangeProvider = true,
      -- linkedEditingRangeProvider = true,
      -- callHierarchyProvider = true,
      -- semanticTokensProvider = {},
      -- monikerProvider = true,
      -- typeHierarchyProvider = true,
      -- inlineValueProvider = true,
      -- inlayHintProvider = true,
      -- diagnosticProvider = {},
      workspaceSymbolProvider = {
        -- resolveProvider = true
      },
      -- workspace={},
      experimental = {
        untitledDocumentCompletions = true, -- custom for this server
        untitledDocumentSignatureHelp = true -- custom for this server
      }
    }
    -- serverInfo = 'Textadept'
  }
end)

-- LSP initialized notification.
register('initialized', function() end) -- no-op

-- LSP textDocument/didOpen notification.
register('textDocument/didOpen', function(params)
  local lines = {}
  for line in params.textDocument.text:gmatch('[^\n]*\n?') do lines[#lines + 1] = line end
  files[params.textDocument.uri] = lines
  log('Cached: ', params.textDocument.uri)
end)

register('textDocument/didClose', function() end)
register('textDocument/didSave', function() end)

-- Scans directory or file *target* and caches the result.
-- @param target String directory or file path.
local function scan(target)
  log('Scanning: ', target)

  -- Determine files to scan.
  local files, seen = {}, 0
  if lfs.attributes(target, 'mode') == 'directory' then
    local config_file, config = target .. '/.lua-lsp', {
      ignore = {'*.hg', '*.git', '*.bzr', '*.svn', '*_FOSSIL_', '*node_modules'}, max_scan = 10000
    }
    if lfs.attributes(config_file) then
      log('Reading config: ' .. config_file)
      local ok, errmsg = pcall(assert(loadfile(target .. '/.lua-lsp', 't', config)))
      if not ok then log('Config error: ' .. errmsg) end
      log('Read config')
    end
    local fnmatch = pl_dir.fnmatch
    local function walk(dir)
      for _, path in ipairs(pl_dir.getdirectories(dir)) do
        if config.ignore then
          for _, ignore in ipairs(config.ignore) do
            if fnmatch(path:sub(#target + 2), ignore) then goto continue end
          end
        end
        walk(path)
        if seen > config.max_scan then
          log('Directory too large')
          return
        end
        ::continue::
      end
      log('Scanning: ', dir)
      for _, path in ipairs(pl_dir.getfiles(dir)) do
        if path:find('%.luad?o?c?$') then files[#files + 1] = path end
        seen = seen + 1
      end
    end
    walk(target)
  else
    files[1] = target
  end
  log('Identified ', #files, ' files to scan')
  if #files == 0 then return end

  -- Write LDoc config.
  local config = cache .. '/config.ld'
  local f = assert(io.open(config, 'wb'))
  f:write('file=', require('pl.pretty').write(files)):close()
  log('Wrote config file: ', config)

  -- Invoke LDoc.
  local command = string.format(
    '%s -d "%s" -c "%s" . --filter tadoc.ldoc -- --root="%s" --multiple', ldoc, cache, config,
    target)
  log('Scan: ', command)
  os.execute(command)

  -- Register results.
  tags, api = {}, {} -- clear
  for filename in lfs.dir(cache) do
    if filename:find('_tags$') then tags[#tags + 1] = cache .. '/' .. filename end
    if filename:find('_api$') then api[#api + 1] = cache .. '/' .. filename end
  end
  log('Read cache: #tags=', #tags, ' #api=', #api)
end

local tmpfiles = {} -- holds the prefixes for temporary file scan results
-- LSP textDocument/didChange notification.
register('textDocument/didChange', function(params)
  if tmpfiles[params.textDocument.uri] then
    local tmpfile = tmpfiles[params.textDocument.uri]
    log('Removing temporary scan results: ', tmpfile, '*')
    for file in lfs.dir(cache) do
      if file:find(tmpfile, 1, true) then os.remove(cache .. '/' .. file) end
    end
    tmpfiles[params.textDocument.uri] = nil
  end

  local lines = {}
  for line in params.contentChanges[1].text:gmatch('[^\n]*') do lines[#lines + 1] = line end
  files[params.textDocument.uri] = lines
  log('Cached: ', params.textDocument.uri)
  -- Scan it, but with a path relative to a temporary root directory.
  -- This allows "Go to Definition" to function correctly for files with unsaved changes.
  local tmpdir = os.tmpname()
  os.remove(tmpdir) -- Linux creates this file
  local filename = tofilename(params.textDocument.uri)
  if filename:sub(1, #root) == root then filename = filename:sub(#root + 2) end
  if WIN32 then filename = filename:gsub('^%a:', '') end
  log('Preparing to scan: ', tofilename(params.textDocument.uri), ' relative path=', filename)
  local path = tmpdir .. '/' .. filename
  pl_dir.makepath(path:match('^.+[/\\]'))
  log('Creating temporary file: ', filename)
  io.open(path, 'wb'):write(params.contentChanges[1].text):close()
  scan(tmpdir)
  tmpfiles[params.textDocument.uri] = tmpdir:gsub('[/\\]', '_') -- tadoc saves files like this
  pl_dir.rmtree(tmpdir)
end)

-- Map of expression patterns to their types.
-- Used for type-hinting when showing autocompletions for variables. Expressions are expected
-- to match after the '=' sign of a statement.
-- @class table
-- @name expr_types
-- @usage expr_types['^spawn%b()%s*$'] = 'proc'
local expr_types = {['^[\'"]'] = 'string', ['^io%.p?open%s*%b()%s*$'] = 'file'}

-- Map of ctags kinds to LSP CompletionItemKinds.
local kinds = {m = 7, f = 3, F = 5, t = 8}

-- LSP textDocument/completion request.
-- Uses the text previously sent via textDocument/didChange to determine the symbol at the
-- given completion position.
register('textDocument/completion', function(params)
  local items = {}

  -- Retrieve the symbol behind the caret.
  local line_num, col_num = params.position.line + 1, params.position.character + 1
  local lines = files[params.textDocument.uri]
  local symbol, op, part = lines[line_num]:sub(1, col_num - 1):match('([%w_%.]-)([%.:]?)([%w_]*)$')
  log('Getting completions: file=', tofilename(params.textDocument.uri), ' line=', line_num,
    ' col=', col_num, ' symbol=', symbol, ' op=', op, ' part=', part)
  if symbol == '' and part == '' then return json.null end -- nothing to complete
  symbol, part = symbol:gsub('^_G%.?', ''), part ~= '_G' and part or ''
  -- Attempt to identify string type and file type symbols.
  local assignment = '%f[%w_]' .. symbol:gsub('(%p)', '%%%1') .. '%s*=%s*(.*)$'
  for i = line_num - 1, 1, -1 do
    local expr = lines[i]:match(assignment)
    if not expr then goto continue end
    for patt, type in pairs(expr_types) do
      if expr:find(patt) then
        log('Inferred type: symbol=', symbol, ' type=', type)
        symbol = type
        break
      end
    end
    ::continue::
  end

  -- Search through ctags for completions for that symbol.
  local name_patt, seen = '^' .. part, {}
  for _, filename in ipairs(tags) do
    if not filename or not lfs.attributes(filename) then goto continue end
    for line in io.lines(filename) do
      local name = line:match('^%S+')
      if not name:find(name_patt) or seen[name] then goto continue end
      local fields = line:match(';"\t(.*)$')
      local k, class = fields:sub(1, 1), fields:match('class:(%S+)') or ''
      if class == symbol and (op ~= ':' or k == 'f') then
        log('Found completion: ', name, ' file=', filename, ' fields=', fields)
        items[#items + 1], seen[name] = {label = name, kind = kinds[k]}, true
      end
      ::continue::
    end
    ::continue::
  end

  if #items == 1 and items[1].label:find(name_patt .. '%?') then return json.null end
  return items
end)

-- Returns the symbol at a text document position.
-- @params LSP TextDocumentPositionParams object.
-- @return symbol or nil
local function get_symbol(params)
  local line_num, col_num = params.position.line + 1, params.position.character + 1
  local line = files[params.textDocument.uri][line_num]
  local symbol_part_right = line:match('^[%w_]*', col_num)
  local symbol_part_left = line:sub(1, col_num - 1):match('[%w_.:]*$')
  local symbol = symbol_part_left .. symbol_part_right
  return symbol ~= '' and symbol or nil
end

-- Returns a list of API docs for the given symbol.
-- @param symbol String symbol get get API docs for.
-- @return list of documentation strings
local function get_api(symbol)
  local docs = {}
  local symbol_patt = '^' .. symbol:match('[%w_]+$')
  for _, filename in ipairs(api) do
    if not filename or not lfs.attributes(filename) then goto continue end
    for line in io.lines(filename) do
      if not line:find(symbol_patt) then goto continue end
      log('Found api: ', symbol, ' file=', filename)
      local doc = line:match(symbol_patt .. '%s+(.+)$')
      if not doc then goto continue end
      docs[#docs + 1] = doc:gsub('%f[\\]\\n', '\n'):gsub('\\\\', '\\')
      ::continue::
    end
    ::continue::
  end
  return docs
end

-- LSP textDocument/hover request.
register('textDocument/hover', function(params)
  local symbol = get_symbol(params)
  if not symbol then return json.null end
  log('Hover: ', symbol)
  local docs = get_api(symbol)
  return #docs > 0 and {contents = {kind = 'plaintext', value = docs[1]}} or json.null
end)

-- LSP textDocument/signatureHelp request.
register('textDocument/signatureHelp', function(params)
  local signatures = {}

  -- Retrieve the function behind the caret.
  local line_num, col_num = params.position.line + 1, params.position.character + 1
  local lines, prev_lines = files[params.textDocument.uri], {}
  for i = 1, line_num - 1 do prev_lines[#prev_lines + 1] = lines[i] end
  local text, pos = table.concat(lines), #table.concat(prev_lines) + col_num - 1
  log('Getting signature: file=', params.textDocument.uri, ' line=', line_num, ' col=', col_num,
    ' pos=', pos)
  local s = pos
  ::retry::
  while s > 1 and not text:find('^[({]', s) do s = s - 1 end
  local e = select(2, text:find('^%b()', s)) or select(2, text:find('^%b{}', s))
  if e and e < pos then
    log('Skipping previous () or {}: s=', s, ' e=', e)
    s = s - 1
    goto retry
  end
  local func = text:sub(1, s - 1):match('[%w_]+$')
  if not func then return json.null end
  log('Identified function: ', func)

  for _, doc in ipairs(get_api(func)) do signatures[#signatures + 1] = {label = doc} end
  return {signatures = signatures, activeSignature = 0}
end)

-- LSP textDocument/definition request.
register('textDocument/definition', function(params)
  local locations = {}

  -- Retrieve the symbol at the caret.
  local symbol = get_symbol(params)
  if not symbol then return json.null end
  log('Go to definition of ', symbol)

  -- Search through ctags for that symbol.
  local patt = '^(' .. symbol:match('[%w_]+$') .. ')\t([^\t]+)\t(.-);"\t?(.*)$'
  for _, filename in ipairs(tags) do
    if not filename or not lfs.attributes(filename) then goto continue end
    for tag_line in io.lines(filename) do
      local name, file, ex_cmd, ext_fields = tag_line:match(patt)
      if not name then goto continue end
      file = file:gsub('^_ROOT', root)
      log('Found definition: ', ex_cmd, ' file=', filename)
      local uri = touri(file)
      ex_cmd = ex_cmd:match('/^?(.-)$?/$')
      if files[uri] then
        -- Find definition in cached file.
        for i, line in ipairs(files[uri]) do
          local s, e = line:find(ex_cmd, 1, true)
          if not s and not e then goto continue end
          log('Found location in cached file: line ', i - 1)
          locations[#locations + 1] = {
            uri = uri,
            range = {
              start = {line = i - 1, character = s - 1}, ['end'] = {line = i - 1, character = e}
            }
          }
          break
          ::continue::
        end
        goto continue
      end
      -- Find definition in file on disk.
      local i = 1
      for line in io.lines(file) do
        local s, e = line:find(ex_cmd, 1, true)
        if s and e then
          log('Found location in file: line ', i - 1)
          locations[#locations + 1] = {
            uri = uri,
            range = {
              start = {line = i - 1, character = s - 1}, ['end'] = {line = i - 1, character = e}
            }
          }
          break
        end
        i = i + 1
      end
      ::continue::
    end
    ::continue::
  end

  return locations
end)

-- LSP workspace/symbol request.
register('workspace/symbol', function(params)
  return json.null -- TODO:
end)

-- LSP shutdown request.
register('shutdown', function(params)
  log('Shutting down')
  pl_dir.rmtree(cache)
  log('Cleaned up')
  return json.null
end)

-- Main server loop.
log('Starting up')
local message = read()
while message.method ~= 'exit' do
  log('Request: id=', message.id, ' method=', message.method)
  local ok, result = pcall(handlers[message.method], message.params)
  if not ok then
    log('Error: ', result)
    result = {code = 1, message = result}
  end
  if result then
    log('Response: id=', message.id)
    respond(message.id, result)
  end
  if message.method == 'initialize' then
    if root then scan(root) end
    scan(lfs.currentdir() .. '/doc')
  end
  message = read()
end
log('Exiting')