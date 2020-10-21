-- Copyright 2018-2020 Mitchell. See LICENSE.

local json = require('lsp.dkjson')

-- TODO: LuaDoc links for Server:notify() do not work.

--[[ This comment is for LuaDoc.
---
-- A client for Textadept that communicates over the [Language Server
-- Protocol][] (LSP) with language servers in order to provide autocompletion,
-- calltips, go to definition, and more. It implements version 3.12.0 of the
-- protocol, but does not support all protocol features. The [`Server.new()`]()
-- function contains the client's current set of capabilities.
--
-- Install this module by copying it into your *~/.textadept/modules/* directory
-- or Textadept's *modules/* directory, and then putting the following in your
-- *~/.textadept/init.lua*:
--
--     local lsp = require('lsp')
--
-- You can then set up some language server commands. For example:
--
--     lsp.server_commands.lua = 'lua-lsp'
--     lsp.server_commands.cpp = function()
--       return 'cquery', {
--         cacheDirectory = '/tmp/cquery-cache',
--         compilationDatabaseDirectory = io.get_project_root(),
--         progressReportFrequencyMs = -1
--       }
--     end
--
-- When either Lua or cpp files are opened, their associated language servers
-- are automatically started (one per language, though).
--
-- Language Server features are available from the Tools > Language Server menu.
-- Note that not all language servers may support the menu options. You can
-- assign key bindings for these features, such as:
--
--     keys['ctrl+alt+ '] = function() textadept.editing.autocomplete('lsp') end
--     keys['ctrl+H'] = lsp.signature_help
--     keys.f12 = lsp.goto_definition
--
-- **Note:** If you want to inspect the LSP messages sent back and forth, you
-- can use the Lua command entry to set `require('lsp').log_rpc = true`. It
-- doesn't matter if any LSPs are already active -- from this point forward all
-- messages will be logged to the "[LSP]" buffer.
--
-- **Warning:** Buggy language servers that do not respect the protocol may
-- cause this module and Textadept to hang, waiting for a response. There is no
-- recourse other than to force-quit Textadept and restart.
--
-- [Language Server Protocol]: https://microsoft.github.io/language-server-protocol/specification
-- @field _G.textadept.editing.autocompleters.lsp (function)
--   Autocompleter function for a language server.
-- @field _G.events.LSP_INITIALIZED (string)
--   Emitted when an LSP connection has been initialized.
--   This is useful for sending server-specific notifications to the server upon
--   init via [`Server:notify()`]().
--   Emitted by [`lsp.start()`]().
--   Arguments:
--
--   * _`lang`_: The lexer name of the LSP language.
--   * _`server`_: The LSP server.
-- @field _G.events.LSP_NOTIFICATION (string)
--   Emitted when an LSP server emits an unhandled notification.
--   This is useful for handling server-specific notifications. Responses can be
--   sent via [`Server:respond()`]().
--   An event handler should return `true`.
--   Arguments:
--
--   * _`lang`_: The lexer name of the LSP language.
--   * _`server`_: The LSP server.
--   * _`method`_: The string LSP notification method name.
--   * _`params`_: The table of LSP notification params. Contents may be
--     server-specific.
-- @field log_rpc (bool)
--   Log RPC correspondence to the LSP message buffer.
--   The default value is `false`.
-- @field INDIC_WARN (number)
--   The warning diagnostic indicator number.
-- @field INDIC_ERROR (number)
--   The error diagnostic indicator number.
-- @field show_all_diagnostics (bool)
--   Whether or not to show all diagnostics.
--   The default value is `false`, and assumes any diagnostics on the current
--   line or next line are due to an incomplete statement during something like
--   an autocompletion, signature help, etc. request.
module('lsp')]]
local M = {}

-- Localizations.
local _L = _L
if not rawget(_L, 'Language Server') then
  -- Error messages.
  _L['No project root found'] = 'No project root found'
  -- Dialogs.
  _L['Goto definition'] = 'Goto definition'
  _L['language server is already running'] = 'language server is already running'
  _L['language server shell command:'] = 'language server shell command:'
  _L['Stop Server?'] = 'Stop Server?'
  _L['Stop the language server for'] = 'Stop the language server for'
  _L['Query Symbol...'] = 'Query Symbol...'
  _L['Symbol name or name part:'] = 'Symbol name or name part:'
  -- Status.
  _L['Note: completion list incomplete'] = 'Note: completion list incomplete'
  -- Menu.
  _L['Language Server'] = 'Lan_guage Server'
  _L['Start Server...'] = '_Start Server...'
  _L['Stop Server'] = 'Sto_p Server'
  _L['Goto Workspace Symbol...'] = 'Goto _Workspace Symbol...'
  _L['Goto Document Symbol...'] = 'Goto _Document Symbol...'
  _L['Autocomplete'] = '_Autocomplete'
  _L['Show Hover Information'] = 'Show _Hover Information'
  _L['Show Signature Help'] = 'Show Si_gnature Help'
  _L['Goto Definition'] = 'Goto _Definition'
  _L['Goto Type Definition'] = 'Goto _Type Definition'
  _L['Goto Implementation'] = 'Goto _Implementation'
  _L['Find References'] = 'Find _References'
end

local lsp_events = {'lsp_initialized', 'lsp_notification'}
for _, v in ipairs(lsp_events) do events[v:upper()] = v end

M.log_rpc = false
M.INDIC_WARN = _SCINTILLA.next_indic_number()
M.INDIC_ERROR = _SCINTILLA.next_indic_number()

M.show_all_diagnostics = false

---
-- Map of lexer names to LSP language server commands or configurations, or
-- functions that return either a server command or a configuration.
-- Commands are simple string shell commands. Configurations are tables with the
-- following keys:
--
--   * `command`: String shell command used to run the LSP language server.
--   * `init_options`: Table of initialization options to pass to the language
--     server in the "initialize" request.
-- @class table
-- @name server_commands
M.server_commands = {}

-- Map of lexer names to active LSP servers.
local servers = {}

-- Map of LSP CompletionItemKinds to images used in autocompletion lists.
local xpm_map = {
  0, -- text
  textadept.editing.XPM_IMAGES.METHOD, -- method
  textadept.editing.XPM_IMAGES.METHOD, -- function
  textadept.editing.XPM_IMAGES.SLOT, -- constructor
  textadept.editing.XPM_IMAGES.VARIABLE, -- field
  textadept.editing.XPM_IMAGES.VARIABLE, -- variable
  textadept.editing.XPM_IMAGES.CLASS, -- class
  textadept.editing.XPM_IMAGES.TYPEDEF, -- interface
  textadept.editing.XPM_IMAGES.NAMESPACE, -- module
  textadept.editing.XPM_IMAGES.VARIABLE, -- property
  0, -- unit
  0, -- value
  textadept.editing.XPM_IMAGES.TYPEDEF, -- enum
  0, -- keyword
  0, -- snippet
  0, -- color
  0, -- file
  0, -- reference
  0, -- folder
  textadept.editing.XPM_IMAGES.VARIABLE, -- enum member
  textadept.editing.XPM_IMAGES.VARIABLE, -- constant
  textadept.editing.XPM_IMAGES.STRUCT, -- struct
  textadept.editing.XPM_IMAGES.SIGNAL, -- event
  0, -- operator
  0, -- type parameter
}
local completion_item_kind_set = {} -- for LSP capabilities
for i = 1, #xpm_map do completion_item_kind_set[i] = i end

-- Map of LSP SymbolKinds to names shown in symbol filteredlists.
local symbol_kinds = {
  'File', 'Module', 'Namespace', 'Package', 'Class', 'Method', 'Property',
  'Field', 'Constructor', 'Enum', 'Interface', 'Function', 'Variable',
  'Constant', 'String', 'Number', 'Boolean', 'Array', 'Object', 'Key',
  'Null', 'EnumMember', 'Struct', 'Event', 'Operator', 'TypeParameter'
}
local symbol_kind_set = {} -- for LSP capabilities
for i = 1, #symbol_kinds do symbol_kind_set[i] = i end

-- Table of lexers to running language servers.
local Server = {}

---
-- Starts, initializes, and returns a new language server.
-- @param lang Lexer name of the language server.
-- @param cmd String command to start the language server.
-- @param init_options Optional table of options to be passed to the language
--   server for initialization.
function Server.new(lang, cmd, init_options)
  local root = assert(io.get_project_root(), _L['No project root found'])
  local current_view = view
  ui._print('[LSP]', 'Starting language server: ' .. cmd)
  ui.goto_view(current_view)
  local server = setmetatable(
    {lang = lang, request_id = 0}, {__index = Server})
  server.proc = assert(os.spawn(
    cmd, root, function(output) server:handle_stdout(output) end,
    function(output) server:log(output) end,
    function(status) server:log('Server exited with status ' .. status) end))
  local result = server:request('initialize', {
    processId = json.null,
    rootUri = not WIN32 and 'file://' .. root or
      'file:///' .. root:gsub('\\', '/'),
    initializationOptions = init_options,
    capabilities = {
      --workspace = nil,
      textDocument = {
        synchronization = {
        --  willSave = true,
        --  willSaveWaitUntil = true,
          didSave = true,
        },
        completion = {
          completionItem = {
            --snippetSupport = false, -- ${1:foo} format not supported
            --commitCharacterSupport = true,
            documentationFormat = {'plaintext'},
            --deprecatedSupport = false, -- simple autocompletion list
            preselectSupport = true,
          },
          completionItemKind = {valueSet = completion_item_kind_set},
          --contextSupport = false,
        },
        hover = {contentFormat = {'plaintext'}},
        signatureHelp = {
          signatureInformation = {documentationFormat = {'plaintext'}},
        },
        --references = {},
        --documentHighlight = {},
        documentSymbol = {
          symbolKind = {valueSet = symbol_kind_set},
          --hierarchicalDocumentSymbolSupport = false,
        },
        --formatting = {},
        --rangeFormatting = {},
        --onTypeFormatting = {},
        --definition = {},
        --typeDefinition = {},
        --implementation = {},
        --codeAction = {
        --  codeActionLiteralSupport = {
        --    valueSet = {},
        --  },
        --},
        --codeLens = {},
        --documentLink = {},
        --colorProvider = {},
        --rename = {prepareSupport = false},
        --publishDiagnostics = {},
        --foldingRange = {
        --  rangeLimit = ?,
        --  lineFoldingOnly = true,
        --},
      },
      --experimental = nil
    }
  })
  server.capabilities = result.capabilities
  server:notify('initialized') -- required by protocol
  events.emit(events.LSP_INITIALIZED, server.lang, server)
  return server
end

---
-- Reads and returns an incoming JSON message from this language server.
-- @return table of data from JSON
function Server:read()
  local line = self.proc:read()
  while not line:find('^Content%-Length: %d+$') do line = self.proc:read() end
  local len = tonumber(line:match('%d+$'))
  while #line > 0 do line = self.proc:read() end -- skip other headers
  local data = self.proc:read(len)
  if M.log_rpc then self:log('RPC recv: ' .. data) end
  return json.decode(data)
end

---
-- Sends a request to this language server and returns the result of the
-- request.
-- Any intermediate notifications from the server are processed, but any
-- intermediate requests from the server are ignored.
-- Note: at this time, requests are synchronous, so the id number for a response
-- will be the same as the id number for a request.
-- @param method String method name of the request.
-- @param params Table of parameters for the request.
-- @return table result of the request, or nil if the result was `json.null`.
function Server:request(method, params)
  -- Prepare and send the JSON message.
  self.request_id = self.request_id + 1
  local message = {
    jsonrpc = '2.0', id = self.request_id, method = method, params = params
  }
  local data = json.encode(message)
  if M.log_rpc then self:log('RPC send: ' .. data) end
  self.proc:write(string.format(
    'Content-Length: %d\r\n\r\n%s\r\n', #data + 2, data))
  -- Read incoming JSON messages until the proper response is found.
  repeat
    message = self:read()
    -- TODO: error handling for message
    if not message.id then
      self:handle_notification(message.method, message.params)
    elseif tonumber(message.id) > self.request_id then
      self:log('Ignoring incoming server request: ' .. message.method)
      self.request_id = tonumber(message.id) + 1 -- update
      message.id = nil
    end
  until message.id
  -- Return the response's result.
  return message.result ~= json.null and message.result or nil
end

---
-- Sends a notification to this language server.
-- @param method String method name of the notification.
-- @param params Table of parameters for the notification.
function Server:notify(method, params)
  local message = {jsonrpc = '2.0', method = method, params = params or {}}
  local data = json.encode(message)
  if M.log_rpc then self:log('RPC send: ' .. data) end
  self.proc:write(string.format(
    'Content-Length: %d\r\n\r\n%s\r\n', #data + 2, data))
end

---
-- Responds to an unsolicited request from this language server.
-- @param id Numeric ID of the request.
-- @param result Table result of the request.
function Server:respond(id, result)
  local message = {jsonrpc = '2.0', id = id, result = result}
  local data = json.encode(message)
  if M.log_rpc then self:log('RPC send: ' .. data) end
  self.proc:write(string.format(
    'Content-Length: %d\r\n\r\n%s\r\n', #data + 2, data))
end

---
-- Processes unsolicited, incoming stdout from the Language Server, primarily to
-- look for notifications and act on them.
-- @param output String stdout from the Language Server.
function Server:handle_stdout(output)
  if output:find('^Content%-Length:') then
    local len = tonumber(output:match('^Content%-Length: (%d+)'))
    local _, _, e = output:find('\r\n\r\n()')
    local message = json.decode(output:sub(e, e + len - 1))
    if not message.id then
      self:handle_notification(message.method, message.params)
    else
      self:log('Ignoring incoming server request: ' .. message.method)
    end
    self:handle_stdout(output:sub(e + len)) -- process any other messages
  elseif output:find('^%S+$') then
    -- TODO: handle split messages properly (e.g. cache parts)
    self:log(output)
  end
end

---
-- Silently logs the given message.
-- @param message String message to log.
function Server:log(message)
  local silent_print = ui.silent_print
  ui.silent_print = true
  ui._print('[LSP]', message)
  ui.silent_print = silent_print -- restore
end

-- Converts the given LSP DocumentUri into a valid filename and returns it.
-- @param uri LSP DocumentUri to convert into a filename.
local function tofilename(uri)
  local filename = uri:gsub(not WIN32 and '^file://' or '^file:///', '')
  filename = filename:gsub(
    '%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
  if WIN32 then filename = filename:gsub('/', '\\') end
  return filename
end

-- Returns the start and end buffer positions for the given LSP Range.
-- @param range LSP Range.
local function tobufferrange(range)
  local s = buffer:position_from_line(range.start.line + 1) +
    range.start.character + 1
  local e = buffer:position_from_line(range['end'].line + 1) +
    range['end'].character + 1
  return s, e
end

---
-- Handles an unsolicited notification from this language server.
-- @param method String method name of the notification.
-- @param params Table of parameters for the notification.
function Server:handle_notification(method, params)
  if method:find('^window/showMessage') then
    -- Show a message to the user.
    local icons = {'gtk-dialog-error', 'gtk-dialog-warning', 'gtk-dialog-info'}
    local dialog_options = {
      icon = icons[params.type], text = params.message, string_output = true
    }
    if not method:find('Request') then
      ui.dialogs.ok_msgbox(dialog_options)
    else
      -- Present options in the message and respond with the selected option.
      for i = 1, #params.actions do
        dialog_options['button' .. i] = params.actions[i].title
      end
      local result = {title = ui.dialogs.msgbox(dialog_options)}
      -- TODO: option cannot be "delete"
      if result.title == 'delete' then result = json.null end
      self:respond(params.id, result)
    end
  elseif method == 'window/logMessage' then
    -- Silently log a message.
    local level = {'ERROR', 'WARN', 'INFO', 'LOG'}
    self:log(string.format('%s: %s', level[params.type], params.message))
  elseif method == 'telemetry/event' then
    -- Silently log an event.
    self:log(string.format('TELEMETRY: %s', json.encode(params)))
  elseif method == 'textDocument/publishDiagnostics' then
    -- Annotate the buffer based on diagnostics.
    if buffer.filename ~= tofilename(params.uri) then return end
    for _, indic in ipairs{M.INDIC_WARN, M.INDIC_ERROR} do
      buffer.indicator_current = indic
      buffer:indicator_clear_range(1, buffer.length)
    end
    buffer:annotation_clear_all()
    for _, diagnostic in ipairs(params.diagnostics) do
      buffer.indicator_current =
        (not diagnostic.severity or diagnostic.severity == 1) and
        M.INDIC_ERROR or M.INDIC_WARN
      local s, e = tobufferrange(diagnostic.range)
      local line = buffer:line_from_position(e)
      local current_line = buffer:line_from_position(buffer.current_pos)
      if M.show_all_diagnostics or
         (current_line ~= line and current_line + 1 ~= line) then
        buffer:indicator_fill_range(s, e - s)
        buffer.annotation_text[line] = diagnostic.message
        local GETNAMEDSTYLE = _SCINTILLA.properties.named_styles[1]
        local style = buffer:private_lexer_call(GETNAMEDSTYLE, 'error')
        buffer.annotation_style[line] = style
        -- TODO: diagnostics should be persistent in projects.
      end
    end
  elseif not events.emit(
           events.LSP_NOTIFICATION, self.lang, self, method, params) then
    -- Unknown notification.
    self:log('unexpected notification: ' .. method)
  end
end

---
-- Synchronizes the current buffer with this language server.
-- Changes are not synchronized in real-time, but whenever a request is about to
-- be sent.
function Server:sync_buffer()
  self:notify('textDocument/didChange', {
    textDocument = {
      uri = not WIN32 and 'file://' .. buffer.filename or
        'file:///' .. buffer.filename:gsub('\\', '/'),
      version = os.time() -- just make sure it keeps increasing
    },
    contentChanges = {{text = buffer:get_text()}}
  })
end

---
-- Notifies this language server that the given buffer was opened.
-- @param buffer Buffer opened.
function Server:notify_opened(buffer)
  self:notify('textDocument/didOpen', {textDocument = {
    uri = not WIN32 and 'file://' .. buffer.filename or
      'file:///' .. buffer.filename:gsub('\\', '/'),
    languageId = buffer:get_lexer(), version = 0, text = buffer:get_text()
  }})
end

---
-- Starts a language server based on the current language.
-- @name start
function M.start()
  local lang = buffer:get_lexer()
  if servers[lang] then return end -- already running
  servers[lang] = true -- sentinel until initialization is complete
  local cmd, init_options = M.server_commands[lang], nil
  if type(cmd) == 'function' then cmd, init_options = cmd() end
  if type(cmd) == 'table' then
    cmd, init_options = cmd.command, cmd.init_options
  end
  local ok, server = pcall(Server.new, lang, cmd, init_options)
  servers[lang] = ok and server or nil -- replace sentinel
  assert(ok, server)
  -- Send file opened notifications for open files.
  for _, buffer in ipairs(_BUFFERS) do
    if buffer.filename and buffer:get_lexer() == lang then
      server:notify_opened(buffer)
    end
  end
end

---
-- Stops a running language server based on the current language.
-- @name stop
function M.stop()
  local server = servers[buffer:get_lexer()]
  if not server then return end
  server:request('shutdown')
  server:notify('exit')
  servers[buffer:get_lexer()] = nil
end

-- Returns a LSP TextDocumentPositionParams structure based on the current
-- position in the current buffer.
-- @return table LSP TextDocumentPositionParams
local function get_buffer_position_params()
  return {
    textDocument = {
      uri = not WIN32 and 'file://' .. buffer.filename or
        'file:///' .. buffer.filename:gsub('\\', '/')
    },
    position = {
      line = buffer:line_from_position(buffer.current_pos) - 1,
      character = buffer.column[buffer.current_pos] - 1
    }
  }
end

-- Jumps to the given LSP Location structure.
-- @param location LSP Location to jump to.
local function goto_location(location)
  ui.goto_file(tofilename(location.uri))
  buffer:set_sel(tobufferrange(location.range))
end

-- Jumps to the symbol selected from a list of LSP SymbolInformation or
-- structures.
-- @param symbols List of LSP SymbolInformation or DocumentSymbol structures.
local function goto_selected_symbol(symbols)
  -- Prepare items for display in a filteredlist dialog.
  local items = {}
  for _, symbol in ipairs(symbols) do
    items[#items + 1] = symbol.name
    items[#items + 1] = symbol_kinds[symbol.kind]
    if not symbol.location then
      -- LSP DocumentSymbol has `range` instead of `location`.
      symbol.location = {
        uri = not WIN32 and buffer.filename or buffer.filename:gsub('\\', '/'),
        range = range
      }
    end
    items[#items + 1] = tofilename(symbol.location.uri)
  end
  -- Show the dialog.
  local button, i = ui.dialogs.filteredlist{
    title = 'Goto Symbol', columns = {'Name', 'Kind', 'Location'}, items = items
  }
  if button == -1 then return end
  -- Jump to the selected symbol.
  goto_location(symbols[i].location)
end

---
-- Jumps to a symbol selected from a list based on project symbols that match
-- the given symbol, or based on buffer symbols.
-- @param symbol Optional string symbol to query for in the current project. If
--   `nil`, symbols are presented from the current buffer.
-- @name goto_symbol
function M.goto_symbol(symbol)
  local server = servers[buffer:get_lexer()]
  if not server or not buffer.filename then return end
  server:sync_buffer()
  local symbols
  if symbol and server.capabilities.workspaceSymbolProvider then
    -- Fetching project symbols that match the query.
    symbols = server:request('workspace/symbol', {query = symbol})
  elseif server.capabilities.documentSymbolProvider then
    -- Fetching symbols in the current buffer.
    symbols = server:request('textDocument/documentSymbol', {textDocument = {
      uri = not WIN32 and 'file://' .. buffer.filename or
        'file:///' .. buffer.filename:gsub('\\', '/')
    }})
  end
  if symbols and #symbols > 0 then goto_selected_symbol(symbols) end
end

-- Autocompleter function using a language server.
textadept.editing.autocompleters.lsp = function()
  local server = servers[buffer:get_lexer()]
  if server and buffer.filename and server.capabilities.completionProvider then
    server:sync_buffer()
    -- Fetch a completion list.
    local completions = server:request(
      'textDocument/completion', get_buffer_position_params())
    if not completions then return end
    if completions.isIncomplete then
      ui.statusbar_text = _L['Note: completion list incomplete']
    end
    if completions.items then completions = completions.items end
    if #completions == 0 then return end
    -- Associate completion items with icons.
    local symbols = {}
    for _, symbol in ipairs(completions) do
      local label = symbol.textEdit and symbol.textEdit.newText or
        symbol.insertText or symbol.label
      -- TODO: some labels can have spaces and need proper handling.
      symbols[#symbols + 1] = string.format(
        '%s?%d', label, xpm_map[symbol.kind]) -- TODO: auto_c_type_separator
      -- TODO: if symbol.preselect then symbols.selected = label end?
    end
    -- Return the autocompletion list.
    local len_entered
    if symbols[1].textEdit then
      local s, e = tobufferrange(symbols[1].textEdit.range)
      len_entered = e - s
    else
      local s = buffer:word_start_position(buffer.current_pos, true)
      len_entered = buffer.current_pos - s
    end
    return len_entered, symbols
  end
end

---
-- Shows a calltip with information about the identifier at the given or current
-- position.
-- @param position Optional buffer position of the identifier to show
--   information for. If `nil`, uses the current buffer position.
-- @name hover
function M.hover(position)
  local server = servers[buffer:get_lexer()]
  if server and buffer.filename and server.capabilities.hoverProvider then
    server:sync_buffer()
    local hover = server:request(
      'textDocument/hover', get_buffer_position_params())
    if not hover then return end
    local contents = hover.contents
    if type(contents) == 'table' then
      -- LSP MarkedString[] or MarkupContent.
      for i, content in ipairs(contents) do
        if type(content) == 'table' then contents[i] = content.value end
      end
      contents = contents.value or table.concat(contents, '\n')
    end
    if contents == '' then return end
    view:call_tip_show(position or buffer.current_pos, contents)
  end
end

local signatures
---
-- Shows a calltip for the current function.
-- If a call tip is already shown, cycles to the next one if it exists.
-- @name signature_help
function M.signature_help()
  if view:call_tip_active() then events.emit(events.CALL_TIP_CLICK) return end
  local server = servers[buffer:get_lexer()]
  if server and buffer.filename and
     server.capabilities.signatureHelpProvider then
    server:sync_buffer()
    signatures = server:request(
      'textDocument/signatureHelp', get_buffer_position_params())
    if not signatures or #signatures.signatures == 0 then
      signatures = {} -- reset
      return
    end
    signatures.signatures.active = (signatures.activeSignature or 0) + 1
    signatures = signatures.signatures
    for i, signature in ipairs(signatures) do
      local doc = signature.documentation or ''
      -- Construct calltip text.
      if type(doc) == 'table' then doc = doc.value end -- LSP MarkupContent
      doc = string.format('%s\n%s', signature.label, doc)
      -- Wrap long lines in a rudimentary way.
      local lines, edge_column = {}, view.edge_column
      if edge_column == 0 then edge_column = 80 end
      for line in doc:gmatch('[^\n]+') do
        for j = 1, #line, edge_column do
          lines[#lines + 1] = line:sub(j, j + edge_column - 1)
        end
      end
      doc = table.concat(lines, '\\\n')
      -- Add arrow indicators for multiple signatures.
      if #signatures > 1 then doc = '\001' .. doc:gsub('\n', '\n\002', 1) end
      signatures[i] = doc
    end
    view:call_tip_show(buffer.current_pos, signatures[signatures.active])
  end
end
-- Cycle through signatures.
-- TODO: this conflicts with textadept.editing's CALL_TIP_CLICK handler.
events.connect(events.CALL_TIP_CLICK, function(position)
  local server = servers[buffer:get_lexer()]
  if server and buffer.filename and
     server.capabilities.signatureHelpProvider and signatures and
     signatures.active then
    signatures.active = signatures.active + (position == 1 and -1 or 1)
    if signatures.active > #signatures then
      signatures.active = 1
    elseif signatures.active < 1 then
      signatures.active = #signatures
    end
    view:call_tip_show(buffer.current_pos, signatures[signatures.active])
  end
end)

-- Jumps to the definition of the current kind (e.g. symbol, type, interface),
-- returning whether or not a definition was found.
-- @param kind String LSP method name part after 'textDocument/' (e.g.
--   'definition', 'typeDefinition', 'implementation').
-- @return `true` if a definition was found; `false` otherwise
local function goto_definition(kind)
  local server = servers[buffer:get_lexer()]
  if server and buffer.filename and server.capabilities[kind .. 'Provider'] then
    server:sync_buffer()
    local location = server:request(
      'textDocument/' .. kind, get_buffer_position_params())
    if not location or not location.uri and #location == 0 then return false end
    if not location.uri then
      -- List of LSP Locations, instead of a single Location.
      if #location == 1 then
        location = location[1]
      else
        -- Select one from a filteredlist.
        local items = {}
        for i = 1, #location do
          items[#items + 1] = tofilename(location[i].uri)
        end
        local i = ui.dialogs.filteredlist{
          title = _L['Goto Definition'], columns = _L['Filename'], items = items
        }
        if i == -1 then return true end -- definition found; user canceled
        location = location[i]
      end
    end
    goto_location(location)
    return true
  else
    return false
  end
end

---
-- Jumps to the definition of the current symbol, returning whether or not a
-- definition was found.
-- @return `true` if a definition was found; `false` otherwise.
-- @name goto_definition
function M.goto_definition() return goto_definition('definition') end
---
-- Jumps to the definition of the current type, returning whether or not a
-- definition was found.
-- @return `true` if a definition was found; `false` otherwise.
-- @name goto_type_definition
function M.goto_type_definition() return goto_definition('typeDefinition') end
---
-- Jumps to the implementation of the current symbol, returning whether or not
-- an implementation was found.
-- @return `true` if an implementation was found; `false` otherwise.
-- @name goto_implementation
function M.goto_implementation() return goto_definition('implementation') end

---
-- Searches for project references to the current symbol and prints them.
-- @name find_references
function M.find_references()
  local server = servers[buffer:get_lexer()]
  if server and buffer.filename and server.capabilities.referencesProvider then
    server:sync_buffer()
    local params = get_buffer_position_params()
    params.context = {includeDeclaration = true}
    local locations = server:request('textDocument/references', params)
    if not locations or #locations == 0 then return end
    for _, location in ipairs(locations) do
      -- Print trailing ': ' to enable 'find in files' features like
      -- double-click, menu items, Return keypress, etc.
      ui._print(_L['[Files Found Buffer]'], string.format(
        '%s:%d: ', tofilename(location.uri), location.range.start.line))
    end
  end
end

-- Automatically start language servers if possible.
events.connect(events.LEXER_LOADED, function(name)
  if M.server_commands[name] then M.start() end
end)

-- Notify language servers when files are opened.
events.connect(events.FILE_OPENED, function(filename)
  local server = servers[buffer:get_lexer()]
  if server then server:notify_opened(buffer) end
end)
events.connect(events.FILE_AFTER_SAVE, function(filename, saved_as)
  local server = servers[buffer:get_lexer()]
  if not server then return end
  if saved_as then
    server:notify_opened(buffer)
  else
    server:notify('textDocument/didSave', {textDocument = {
      uri = not WIN32 and 'file://' .. buffer.filename or
        'file:///' .. buffer.filename:gsub('\\', '/'),
      languageId = buffer:get_lexer(), version = 0
    }})
  end
end)

-- TODO: textDocument/didClose

-- Query the language server for hover information when mousing over
-- identifiers.
events.connect(events.DWELL_START, function(position)
  local server = servers[buffer:get_lexer()]
  if server then M.hover(position) end
end)
events.connect(events.DWELL_END, function()
  if not buffer.get_lexer then return end
  local server = servers[buffer:get_lexer()]
  if server then view:call_tip_cancel() end
end)

-- Set diagnostic indicator styles.
events.connect(events.VIEW_NEW, function()
  view.indic_style[M.INDIC_WARN] = view.INDIC_SQUIGGLE
  view.indic_fore[M.INDIC_WARN] = view.property_int['color.yellow']
  view.indic_style[M.INDIC_ERROR] = view.INDIC_SQUIGGLE
  view.indic_fore[M.INDIC_ERROR] = view.property_int['color.red']
end)

-- Gracefully shutdown language servers on reset. They will be restarted as
-- buffers are reloaded.
events.connect(events.RESET_BEFORE, function()
  for _, server in ipairs(servers) do
    server:request('shutdown')
    server:notify('exit')
    servers[buffer:get_lexer()] = nil
  end
end)

-- Add a menu.
-- (Insert 'Language Server' menu in alphabetical order.)
local m_tools = textadept.menu.menubar[_L['Tools']]
local found_area
for i = 1, #m_tools - 1 do
  if not found_area and m_tools[i + 1].title == _L['Bookmarks'] then
    found_area = true
  elseif found_area then
    local label = m_tools[i].title or m_tools[i][1]
    if 'Language Server' < label:gsub('^_', '') or m_tools[i][1] == '' then
      table.insert(m_tools, i, {
        title = _L['Language Server'],
        {_L['Start Server...'], function()
          local server = servers[buffer:get_lexer()]
          if server then
            ui.dialogs.ok_msgbox{
              title = _L['Start Server...']:gsub('_', ''),
              text = string.format(
                '%s %s', buffer:get_lexer(),
                _L['language server is already running']),
              no_cancel = true
            }
            return
          end
          local button, cmd = ui.dialogs.inputbox{
            title = _L['Start Server...']:gsub('_', ''),
            informative_text = string.format(
              '%s %s', buffer:get_lexer(),
              _L['language server shell command:']),
            button1 = _L['OK'], button2 = _L['Cancel']
          }
          if button == 1 and cmd ~= '' then M.start(cmd) end
        end},
        {_L['Stop Server'], function()
          local server = servers[buffer:get_lexer()]
          if not server then return end
          local button = ui.dialogs.ok_msgbox{
            title = _L['Stop Server?'],
            text = string.format(
              '%s %s?', _L['Stop the language server for'], buffer:get_lexer())
          }
          if button == 1 then M.stop() end
        end},
        {''},
        {_L['Goto Workspace Symbol...'], function()
          local server = servers[buffer:get_lexer()]
          if not server then return end
          local button, query = ui.dialogs.inputbox{
            title = _L['Query Symbol...'],
            informative_text = _L['Symbol name or name part:'],
            button1 = _L['OK'], button2 = _L['Cancel']
          }
          if button == 1 and query ~= '' then M.goto_symbol(query) end
        end},
        {_L['Goto Document Symbol...'], M.goto_symbol},
        {_L['Autocomplete'], function()
          textadept.editing.autocomplete('lsp')
        end},
        {_L['Show Hover Information'], M.hover},
        {_L['Show Signature Help'], M.signature_help},
        {_L['Goto Definition'], M.goto_definition},
        {_L['Goto Type Definition'], M.goto_type_definition},
        {_L['Goto Implementation'], M.goto_implementation},
        {_L['Find References'], M.find_references},
      })
      break
    end
  end
end

return M
