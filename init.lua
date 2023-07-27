-- Copyright 2018-2023 Mitchell. See LICENSE.

local json = require('lsp.dkjson')

--- A client for Textadept that communicates over the [Language Server Protocol][] (LSP) with
-- language servers in order to provide autocompletion, calltips, go to definition, and more.
-- It implements version 3.17.0 of the protocol, but does not support all protocol features. The
-- `Server.new()` function contains the client's current set of capabilities.
--
-- Install this module by copying it into your *~/.textadept/modules/* directory or Textadept's
-- *modules/* directory, and then putting the following in your *~/.textadept/init.lua*:
--
--	local lsp = require('lsp')
--
-- You can then set up some language server commands. For example:
--
--	lsp.server_commands.cpp = 'clangd'
--	lsp.server_commands.go = 'gopls'
--
-- (For more example configurations, see the [wiki][].)
--
-- When either C++ or Go files are opened, their associated language servers are automatically
-- started (one per project). Note that language servers typically require a root URI, so this
-- module uses `io.get_project_root()` for this. If the file being opened is not part of a
-- project recognized by Textadept, the language server will not be started.
--
-- Language Server features are available from the Tools > Language Server menu. Note that not
-- all language servers may support the menu options.
--
-- **Note:** If you want to inspect the LSP messages sent back and forth, you can use the Lua
-- command entry to set `require('lsp').log_rpc = true`. It doesn't matter if any LSPs are
-- already active -- from this point forward all messages will be logged. View the log via the
-- "Tools > Language Server > View Log" menu item.
--
-- **Warning:** Buggy language servers that do not respect the protocol may cause this module
-- and Textadept to hang, waiting for a response. There is no recourse other than to force-quit
-- Textadept and restart.
--
-- [Language Server Protocol]: https://microsoft.github.io/language-server-protocol/specification
-- [wiki]: https://github.com/orbitalquark/textadept/wiki/LSP-Configurations
--
-- ### Lua Language Server
--
-- This module comes with a simple Lua language server that starts up when Textadept opens a
-- Lua file. The server looks in the project root for a *.lua-lsp* configuration file. That
-- file can have the following fields:
--
-- - `ignore`: List of globs that match directories and files to ignore. Globs are relative to
--	the project root. The default directories ignored are .bzr, .git, .hg, .svn, _FOSSIL_,
--	and node_modules. Setting this field overrides the default.
-- - `max_scan`: Maximum number of files to scan before giving up. This is not the number of
--	Lua files scanned, but the number of files encountered in non-ignored directories.
--	The primary purpose of this field is to avoid hammering the disk when accidentally
--	opening a large project or root. The default value is 10,000.
--
-- For example:
--
--	ignore = {'.git', 'build', 'test'}
--	max_scan = 20000
--
-- ### Key Bindings
--
-- Windows and Linux | macOS | Terminal | Command
-- -|-|-|-
-- **Tools**| | |
-- Ctrl+Space | ⌘Space<br/> ^Space | ^Space | Complete symbol
-- Ctrl+? | ⌘?<br/>^? | M-?<br/>Ctrl+?<sup>‡</sup> | Show documentation
-- F12 | F12 | F12 | Go To Definition
--
-- ‡: Windows terminal version only.
-- @module lsp
local M = {}

-- Localizations.
local _L = _L
if not rawget(_L, 'Language Server') then
	-- Dialogs.
	_L['language server is already running'] = 'language server is already running'
	_L['language server shell command:'] = 'language server shell command:'
	_L['Stop Server?'] = 'Stop Server?'
	_L['Stop the language server for'] = 'Stop the language server for'
	_L['Symbol name or name part:'] = 'Symbol name or name part:'
	-- Status.
	_L['LSP server started'] = 'LSP server started'
	_L['Unable to start LSP server'] = 'Unable to start LSP server'
	_L['Note: completion list incomplete'] = 'Note: completion list incomplete'
	_L['Showing diagnostics'] = 'Showing diagnostics'
	_L['Hiding diagnostics'] = 'Hiding diagnostics'
	-- Menu.
	_L['Language Server'] = 'Lan_guage Server'
	_L['Start Server...'] = '_Start Server...'
	_L['Stop Server'] = 'Sto_p Server'
	_L['Go To Workspace Symbol...'] = 'Go To _Workspace Symbol...'
	_L['Go To Document Symbol...'] = 'Go To Document S_ymbol...'
	_L['Autocomplete'] = '_Autocomplete'
	_L['Show Documentation'] = 'Show _Documentation'
	_L['Show Hover Information'] = 'Show _Hover Information'
	_L['Show Signature Help'] = 'Show Si_gnature Help'
	_L['Go To Declaration'] = 'Go To De_claration'
	_L['Go To Definition'] = 'Go To De_finition'
	_L['Go To Type Definition'] = 'Go To _Type Definition'
	_L['Go To Implementation'] = 'Go To _Implementation'
	_L['Find References'] = 'Find _References'
	_L['Select Around'] = 'Select Aro_und'
	_L['Select All Symbol'] = 'Select Al_l Symbol'
	_L['Toggle Show Diagnostics'] = 'Toggle Show Diag_nostics'
	_L['Show Log'] = 'Show L_og'
	_L['Clear Log'] = 'Cl_ear Log'
end

-- Events.
local lsp_events = {'lsp_initialized', 'lsp_notification', 'lsp_request'}
for _, v in ipairs(lsp_events) do events[v:upper()] = v end

--- Emitted when an LSP connection has been initialized.
-- This is useful for sending server-specific notifications to the server upon init via
-- `Server:notify()`.
-- Emitted by `lsp.start()`.
-- Arguments:
--
-- - *lang*: The lexer name of the LSP language.
-- - *server*: The LSP server.
-- @field _G.events.LSP_INITIALIZED

--- Emitted when an LSP server emits an unhandled notification.
-- This is useful for handling server-specific notifications.
-- An event handler should return `true`.
-- Arguments:
--
-- - *lang*: The lexer name of the LSP language.
-- - *server*: The LSP server.
-- - *method*: The string LSP notification method name.
-- - *params*: The table of LSP notification params. Contents may be server-specific.
-- @field _G.events.LSP_NOTIFICATION

--- Emitted when an LSP server emits an unhandled request.
-- This is useful for handling server-specific requests. Responses are sent using
-- `Server:respond()`.
-- An event handler should return `true`.
-- Arguments:
--
-- - *lang*: The lexer name of the LSP language.
-- - *server*: The LSP server.
-- - *id*: The integer LSP request ID.
-- - *method*: The string LSP request method name.
-- - *params*: The table of LSP request params.
-- @field _G.events.LSP_REQUEST

--- Log RPC correspondence to the LSP message buffer.
-- The default value is `false`.
M.log_rpc = false
--- Whether or not to automatically show completions when a trigger character is typed (e.g. '.').
-- The default value is `true`.
M.show_completions = true
--- Whether or not to allow completions to insert snippets instead of plain text, for language
-- servers that support it.
-- The default value is `true`.
M.snippet_completions = true
--- Whether or not to automatically show signature help when a trigger character is typed
-- (e.g. '(').
-- The default value is `true`.
M.show_signature_help = true
--- Whether or not to automatically show symbol information via mouse hovering.
-- The default value is `true`.
M.show_hover = true
--- Whether or not to show diagnostics.
-- The default value is `true`, and shows them as annotations.
M.show_diagnostics = true
--- Whether or not to show all diagnostics if `show_diagnostics` is `true`.
-- The default value is `false`, and assumes any diagnostics on the current line or next line
-- are due to an incomplete statement during something like an autocompletion, signature help,
-- etc. request.
M.show_all_diagnostics = false
--- The number of characters typed after which autocomplete is automatically triggered.
-- The default value is `nil`, which disables this feature. A value greater than or equal to
-- 3 is recommended to enable this feature.
M.autocomplete_num_chars = nil

--- Map of lexer names to LSP language server commands or configurations, or functions that
-- return either a server command or a configuration.
-- Commands are simple string shell commands. Configurations are tables with the following keys:
--
-- - *command*: String shell command used to run the LSP language server.
-- - *init_options*: Table of initialization options to pass to the language server in the
--	"initialize" request.
M.server_commands = {}

--- Map of lexer names to maps of project roots and their active LSP servers.
local servers = {}

--- Map of LSP CompletionItemKinds to images used in autocompletion lists.
local xpm_map = {} -- empty declaration to avoid LDoc processing
xpm_map = {
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
	0 -- type parameter
}
local completion_item_kind_set = {} -- for LSP capabilities
for i = 1, #xpm_map do completion_item_kind_set[i] = i end

--- Map of LSP SymbolKinds to names shown in symbol lists.
local symbol_kinds = {
	'File', 'Module', 'Namespace', 'Package', 'Class', 'Method', 'Property', 'Field', 'Constructor',
	'Enum', 'Interface', 'Function', 'Variable', 'Constant', 'String', 'Number', 'Boolean', 'Array',
	'Object', 'Key', 'Null', 'EnumMember', 'Struct', 'Event', 'Operator', 'TypeParameter'
}
local symbol_kind_set = {} -- for LSP capabilities
for i = 1, #symbol_kinds do symbol_kind_set[i] = i end

local log_lines, log_buffer = {}, nil
--- Logs the given arguments to the log buffer.
local function log(...)
	log_lines[#log_lines + 1] = table.concat(table.pack(...))
	if not log_buffer then return end
	if not _BUFFERS[log_buffer] then
		log_buffer = nil
		for _, buffer in ipairs(_BUFFERS) do
			if buffer._type ~= '[LSP]' then goto continue end
			log_buffer = buffer
			break
			::continue::
		end
		if not log_buffer then return end
	end
	ui.print_silent_to('[LSP]', log_lines[#log_lines])
end

--- Table of lexers to running language servers.
local Server = {}

--- Starts, initializes, and returns a new language server.
-- @param lang Lexer name of the language server.
-- @param root Root directory of the project for this language server.
-- @param cmd String command to start the language server.
-- @param init_options Optional table of options to be passed to the language server for
--	initialization.
-- @local
function Server.new(lang, root, cmd, init_options)
	log('Starting language server: ', cmd)
	local server = setmetatable({lang = lang, root = root, request_id = 0, incoming_messages = {}},
		{__index = Server})
	server.proc = assert(os.spawn(cmd, function(output) server:handle_stdout(output) end,
		function(output) log(output) end, function(status)
			log('Server exited with status ', status)
			servers[lang][root] = nil
		end))
	local root = io.get_project_root()
	local result = server:request('initialize', {
		processId = json.null, --
		clientInfo = {name = 'textadept', version = _RELEASE},
		-- TODO: locale
		rootUri = root and (not WIN32 and 'file://' .. root or 'file:///' .. root:gsub('\\', '/')) or
			nil, --
		initializationOptions = init_options, --
		capabilities = {
			-- workspace = nil, -- workspaces are not supported at all
			textDocument = {
				synchronization = {
					-- willSave = true,
					-- willSaveWaitUntil = true,
					didSave = true
				}, --
				completion = {
					-- dynamicRegistration = false, -- not supported
					completionItem = {
						snippetSupport = M.snippet_completions,
						-- commitCharactersSupport = true,
						documentationFormat = {'plaintext'},
						-- deprecatedSupport = false, -- simple autocompletion list
						preselectSupport = true
						-- tagSupport = {valueSet = {}},
						-- insertReplaceSupport = true,
						-- resolveSupport = {properties = {}},
						-- insertTextModeSupport = {valueSet = {}},
						-- labelDetailsSupport = true
					}, --
					completionItemKind = {valueSet = completion_item_kind_set}
					-- contextSupport = true,
					-- insertTextMode = 1,
					-- completionList = {}
				}, --
				hover = {
					-- dynamicRegistration = false, -- not supported
					contentFormat = {'plaintext'}
				}, --
				signatureHelp = {
					-- dynamicRegistration = false, -- not supported
					signatureInformation = {
						documentationFormat = {'plaintext'}, --
						parameterInformation = {labelOffsetSupport = true}, --
						activeParameterSupport = true
					} --
					-- contextSupport = true
				},
				-- declaration = {
				--	dynamicRegistration = false, -- not supported
				--	linkSupport = true
				-- }
				-- definition = {
				--	dynamicRegistration = false, -- not supported
				--	linkSupport = true
				-- },
				-- typeDefinition = {
				--	dynamicRegistration = false, -- not supported
				--	linkSupport = true
				-- },
				-- implementation = {
				--	dynamicRegistration = false, -- not supported
				--	linkSupport = true
				-- },
				-- references = {dynamicRegistration = false}, -- not supported
				-- documentHighlight = {dynamicRegistration = false}, -- not supported
				documentSymbol = {
					-- dynamicRegistration = false, -- not supported
					symbolKind = {valueSet = symbol_kind_set}
					-- hierarchicalDocumentSymbolSupport = true,
					-- tagSupport = {valueSet = {}},
					-- labelSupport = true
				} --
				-- codeAction = {
				--	dynamicRegistration = false, -- not supported
				--	codeActionLiteralSupport = {valueSet = {}},
				--	isPreferredSupport = true,
				--	disabledSupport = true,
				--	dataSupport = true,
				--	resolveSupport = {properties = {}},
				--	honorsChangeAnnotations = true
				-- },
				-- codeLens = {dynamicRegistration = false}, -- not supported
				-- documentLink = {
				--	dynamicRegistration = false, -- not supported
				--	tooltipSupport = true
				-- },
				-- colorProvider = {dynamicRegistration = false}, -- not supported
				-- formatting = {dynamicRegistration = false}, -- not supported
				-- rangeFormatting = {dynamicRegistration = false}, -- not supported
				-- onTypeFormatting = {dynamicRegistration = false}, -- not supported
				-- rename = {
				--	dynamicRegistration = false, -- not supported
				--	prepareSupport = false,
				--	prepareSupportDefaultBehavior = 1,
				--	honorsChangeAnnotations = true
				-- },
				-- publishDiagnostics = {
				--	relatedInformation = true,
				--	tagSupport = {valueSet = {}},
				--	versionSupport = true,
				--	codeDescriptionSupport = true,
				--	dataSupport = true
				-- },
				-- foldingRange = {
				--	dynamicRegistration = false, -- not supported
				--	rangeLimit = ?,
				--	lineFoldingOnly = true,
				--	foldingRangeKind = {valueSet = {'comment', 'imports', 'region'}},
				--	foldingRange = {collapsedText = true}
				-- },
				-- selectionRange = {dynamicRegistration = false}, -- not supported
				-- linkedEditingRange = {dynamicRegistration = false}, -- not supported
				-- callHierarchy = {dynamicRegistration = false}, -- not supported
				-- semanticTokens = {
				--	dynamicRegistration = false, -- not supported
				--	requests = {},
				--	tokenTypes = {},
				--	tokenModifiers = {},
				--	formats = {},
				--	overlappingTokenSupport = true,
				--	multilineTokenSupport = true,
				--	serverCancelSupport = true,
				--	augmentsSyntaxTokens = true
				-- },
				-- moniker = {dynamicRegistration = false}, -- not supported
				-- typeHierarchy = {dynamicRegistration = false}, -- not supported
				-- inlineValue = {dynamicRegistration = false}, -- not supported
				-- inlayHint = {
				--	dynamicRegistration = false, -- not supported
				--	resolveSupport = {properties = {}}
				-- },
				-- diagnostic = {
				--	dynamicRegistration = false, -- not supported
				--	relatedDocumentSupport = true
				-- }
			} --
			-- notebookDocument = nil, -- notebook documents are not supported at all
			-- window = {
			--	workDoneProgress = true,
			--	showMessage = {messageActionItem = {additionalPropertiesSupport = true}},
			--	showDocument = {support = true}
			-- },
			-- general = {
			--	staleRequestSupport = {
			--		cancel = true,
			--		retryOnContentModified = {}
			--	},
			--	regularExpressions = {},
			--	markdown = {},
			--	positionEncodings = 'utf-8'
			-- },
			-- experimental = nil
		}
	})
	server.capabilities = result.capabilities
	if server.capabilities.completionProvider then
		server.auto_c_triggers = {}
		for _, char in ipairs(server.capabilities.completionProvider.triggerCharacters or {}) do
			if char ~= ' ' then server.auto_c_triggers[string.byte(char)] = true end
		end
		server.auto_c_fill_ups = table.concat(
			server.capabilities.completionProvider.allCommitCharacters or {})
	end
	if server.capabilities.signatureHelpProvider then
		server.call_tip_triggers = {}
		for _, char in ipairs(server.capabilities.signatureHelpProvider.triggerCharacters or {}) do
			server.call_tip_triggers[string.byte(char)] = true
		end
	end
	server.info = result.serverInfo
	if server.info then
		log(string.format('Connected to %s %s', server.info.name,
			server.info.version or '(unknown version)'))
	end
	server:notify('initialized') -- required by protocol
	events.emit(events.LSP_INITIALIZED, server.lang, server)
	return server
end

--- Reads and returns an incoming JSON message from this language server.
-- @return table of data from JSON
-- @local
function Server:read()
	if self.wait then
		while #self.incoming_messages == 0 do ui.update() end
		self.wait = false
	end
	if #self.incoming_messages > 0 then
		local message = table.remove(self.incoming_messages, 1)
		log('Processing cached message: ', message.id)
		return message
	end
	local line = self.proc:read()
	while not line:find('^\n?Content%-Length: %d+$') do line = self.proc:read() end
	local len = tonumber(line:match('%d+$'))
	while #line > 0 do line = self.proc:read() end -- skip other headers
	local data = self.proc:read(len)
	if M.log_rpc then log('RPC recv: ', data) end
	return json.decode(data)
end

--- Sends a request to this language server and returns the result of the request.
-- Any intermediate notifications from the server are processed, but any intermediate requests
-- from the server are ignored.
-- Note: at this time, requests are synchronous, so the id number for a response will be the
-- same as the id number for a request.
-- @param method String method name of the request.
-- @param params Table of parameters for the request.
-- @return table result of the request, or nil if the result was `json.null`.
-- @local
function Server:request(method, params)
	-- Prepare and send the JSON message.
	self.request_id = self.request_id + 1
	local message = {jsonrpc = '2.0', id = self.request_id, method = method, params = params}
	local data = json.encode(message)
	if M.log_rpc then log('RPC send: ', data) end
	self.proc:write(string.format('Content-Length: %d\r\n\r\n%s\r\n', #data + 2, data))
	-- Read incoming JSON messages until the proper response is found.
	repeat
		message = self:read()
		-- TODO: error handling for message
		if not message.id then
			self:handle_notification(message.method, message.params)
		elseif message.method and not message.result then -- params may be nil
			self:handle_request(message.id, message.method, message.params)
			message.id = nil
		end
	until message.id
	-- Return the response's result.
	if message.error then log('Server returned an error: ', message.error.message) end
	return message.result ~= json.null and message.result or nil
end

local empty_object = json.decode('{}')
--- Sends a notification to this language server.
-- @param method String method name of the notification.
-- @param params Table of parameters for the notification.
-- @local
function Server:notify(method, params)
	local message = {jsonrpc = '2.0', method = method, params = params or empty_object}
	local data = json.encode(message)
	if M.log_rpc then log('RPC send: ', data) end
	self.proc:write(string.format('Content-Length: %d\r\n\r\n%s\r\n', #data + 2, data))
end

--- Responds to an unsolicited request from this language server.
-- @param id Numeric ID of the request.
-- @param result Table result of the request.
-- @local
function Server:respond(id, result)
	local message = {jsonrpc = '2.0', id = id, result = result}
	local data = json.encode(message)
	if M.log_rpc then log('RPC send: ', data) end
	self.proc:write(string.format('Content-Length: %d\r\n\r\n%s\r\n', #data + 2, data))
end

--- Helper function for processing a single message from the Language Server's notification stream.
-- Cache any incoming messages (particularly responses) that happen to be picked up.
-- @param data String message from the Language Server.
-- @local
function Server:handle_data(data)
	if M.log_rpc then log('RPC recv: ', data) end
	local message = json.decode(data)
	if not message.id then
		self:handle_notification(message.method, message.params)
	elseif message.method and not message.result then -- params may be nil
		self:handle_request(message.id, message.method, message.params)
	else
		log('Caching incoming server message: ', message.id)
		table.insert(self.incoming_messages, message)
	end
end

--- Processes unsolicited, incoming stdout from the Language Server, primarily to look for
-- notifications and act on them.
-- @param output String stdout from the Language Server.
-- @local
function Server:handle_stdout(output)
	if output:find('^\n?Content%-Length:') then
		local len = tonumber(output:match('^\n?Content%-Length: (%d+)'))
		local _, _, e = output:find('\r\n\r\n?()')
		if e + len - 1 <= #output then
			self:handle_data(output:sub(e, e + len - 1))
			self:handle_stdout(output:sub(e + len)) -- process any other messages
		else
			self._buf, self._len = output:sub(e), len
		end
	elseif self._buf then
		if #self._buf + #output >= self._len then
			local e = self._len - #self._buf
			self:handle_data(self._buf .. output:sub(1, e))
			self._buf, self._len = nil, nil
			self:handle_stdout(output:sub(e + 1))
		else
			self._buf = self._buf .. output
		end
	elseif not output:find('^%s*$') then
		log('Unhandled server output: ', output)
	end
end

--- Converts the given LSP DocumentUri into a valid filename and returns it.
-- @param uri LSP DocumentUri to convert into a filename.
local function tofilename(uri)
	local filename = uri:gsub(not WIN32 and '^file://' or '^file:///', '')
	filename = filename:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
	if WIN32 then filename = filename:gsub('/', '\\') end
	return filename
end

--- Converts the given filename into a valid LSP DocumentUri and returns it.
-- @param filename String filename to convert into an LSP DocumentUri.
local function touri(filename)
	if filename:find('^%a%a+:') then return filename end -- different scheme like "untitled:"
	return not WIN32 and 'file://' .. filename or 'file:///' .. filename:gsub('\\', '/')
end

--- Returns the start and end buffer positions for the given LSP Range.
-- @param range LSP Range.
local function tobufferrange(range)
	local s = buffer:position_from_line(range.start.line + 1) + range.start.character
	local e = buffer:position_from_line(range['end'].line + 1) + range['end'].character
	return s, e
end

--- Handles an unsolicited notification from this language server.
-- @param method String method name of the notification.
-- @param params Table of parameters for the notification.
-- @local
function Server:handle_notification(method, params)
	if method == 'window/showMessage' then
		-- Show a message to the user.
		ui.statusbar_text = params.message
	elseif method == 'window/logMessage' then
		-- Silently log a message.
		local level = {'ERROR', 'WARN', 'INFO', 'LOG'}
		log(string.format('%s: %s', level[params.type], params.message))
	elseif method == 'telemetry/event' then
		-- Silently log an event.
		log('TELEMETRY: ', json.encode(params))
	elseif method == 'textDocument/publishDiagnostics' and M.show_diagnostics then
		-- Annotate the buffer based on diagnostics.
		if buffer.filename ~= tofilename(params.uri) then return end
		-- Record current line scroll state.
		local current_line = buffer:line_from_position(buffer.current_pos)
		local orig_lines_from_top = view:visible_from_doc_line(current_line) - view.first_visible_line
		-- Clear any existing diagnostics.
		for _, indic in ipairs{textadept.run.INDIC_WARNING, textadept.run.INDIC_ERROR} do
			buffer.indicator_current = indic
			buffer:indicator_clear_range(1, buffer.length)
		end
		buffer:annotation_clear_all()
		-- Add diagnostics.
		for _, diagnostic in ipairs(params.diagnostics) do
			buffer.indicator_current = (not diagnostic.severity or diagnostic.severity == 1) and
				textadept.run.INDIC_ERROR or textadept.run.INDIC_WARNING -- TODO: diagnostic.tags
			local s, e = tobufferrange(diagnostic.range)
			local line = buffer:line_from_position(e)
			if M.show_all_diagnostics or (current_line ~= line and current_line + 1 ~= line) then
				buffer:indicator_fill_range(s, e - s)
				buffer.annotation_text[line] = diagnostic.message
				buffer.annotation_style[line] = buffer:style_of_name(lexer.ERROR)
				-- TODO: diagnostics should be persistent in projects.
			end
		end
		if #params.diagnostics > 0 then buffer._lsp_diagnostic_time = os.time() end
		-- Restore line scroll state.
		local lines_from_top = view:visible_from_doc_line(current_line) - view.first_visible_line
		view:line_scroll(0, lines_from_top - orig_lines_from_top)
	elseif method:find('^%$/') then
		log('Ignoring notification: ', method)
	elseif not events.emit(events.LSP_NOTIFICATION, self.lang, self, method, params) then
		-- Unknown notification.
		log('Unexpected notification: ', method)
	end
end

--- Responds to a request from this language server.
-- @param id ID number of the server's request.
-- @param method String method name of the request.
-- @param params Table of parameters for the request.
-- @local
function Server:handle_request(id, method, params)
	if method == 'window/showMessageRequest' then
		-- Show a message to the user and wait for a response.
		local icons = {'dialog-error', 'dialog-warning', 'dialog-information'}
		local dialog_options = {icon = icons[params.type], title = 'Message', text = params.message}
		-- Present options in the message and respond with the selected option.
		for i = 1, #params.actions do dialog_options['button' .. i] = params.actions[i].title end
		local result = {title = params.actions[ui.dialogs.message(dialog_options)]}
		if not result.title then result = json.null end
		self:respond(id, result)
	elseif not events.emit(events.LSP_REQUEST, self.lang, self, id, method, params) then
		-- Unknown notification.
		log('Responding with null to server request: ', method)
		self:respond(id, nil)
	end
end

--- Synchronizes the current buffer with this language server.
-- Changes are not synchronized in real-time, but whenever a request is about to be sent.
-- @local
function Server:sync_buffer()
	self:notify('textDocument/didChange', {
		textDocument = {
			uri = touri(buffer.filename or 'untitled:'), -- if server supports untitledDocumentCompletions
			version = os.time() -- just make sure it keeps increasing
		}, --
		contentChanges = {{text = buffer:get_text()}}
	})
	if WIN32 then self.wait = true end -- prefer async response reading
end

--- Notifies this language server that the current buffer was opened, provided the language
-- server has not previously been notified.
-- @local
function Server:notify_opened()
	if not self._opened then self._opened = {} end
	if not buffer.filename or self._opened[buffer.filename] then return end
	self:notify('textDocument/didOpen', {
		textDocument = {
			uri = touri(buffer.filename), languageId = buffer.lexer_language, version = 0,
			text = buffer:get_text()
		}
	})
	self._opened[buffer.filename] = true
end

--- Returns a running language server, if one exists, for the current language and project.
-- Sub-projects use their parent project's language server.
local function get_server()
	local lang = buffer.lexer_language
	if not servers[lang] then servers[lang] = {} end
	local root = io.get_project_root()
	if not root and lang == 'lua' then root = '' end -- special case
	if not root then return nil end
	local lang_servers = servers[lang]
	local server = lang_servers[root]
	if server then return server end
	for path, server in pairs(lang_servers) do if root:sub(1, #path) == path then return server end end
end

--- Starts a language server based on the current language and project.
-- @param cmd Optional language server command to run. The default is read from `server_commands`.
function M.start(cmd)
	if get_server() then return end -- already running
	local lang = buffer.lexer_language
	if not cmd then cmd = M.server_commands[lang] end
	local init_options = nil
	if type(cmd) == 'function' then cmd, init_options = cmd() end
	if type(cmd) == 'table' then cmd, init_options = cmd.command, cmd.init_options end
	if not cmd then return end

	local root = buffer.filename and io.get_project_root(buffer.filename)
	if not root and lang == 'lua' and cmd:find('server%.lua') then root = '' end -- special case
	if not root then return end

	servers[lang][root] = true -- sentinel until initialization is complete
	local ok, server = xpcall(Server.new, function(errmsg)
		local message = _L['Unable to start LSP server'] .. ': ' .. errmsg
		log(debug.traceback(message))
		ui.statusbar_text = message
	end, lang, root, cmd, init_options)
	servers[lang][root] = ok and server or nil -- replace sentinel
	if not ok then return end
	server:notify_opened()
	ui.statusbar_text = _L['LSP server started']
end

--- Stops a running language server based on the current language.
function M.stop()
	local server = get_server()
	if not server then return end
	server:request('shutdown')
	server:notify('exit')
	servers[server.lang][server.root] = nil
end

--- Returns a LSP TextDocumentPositionParams structure based on the given or current position
-- in the current buffer.
-- @param position Optional buffer position to use. If `nil`, uses the current buffer position.
-- @return table LSP TextDocumentPositionParams
local function get_buffer_position_params(position)
	local line = buffer:line_from_position(position or buffer.current_pos)
	return {
		textDocument = {
			uri = touri(buffer.filename or 'untitled:') -- server may support untitledDocumentCompletions
		}, --
		position = {
			line = line - 1,
			character = (position or buffer.current_pos) - buffer:position_from_line(line)
		}
	}
end

--- Jumps to the given LSP Location structure.
-- @param location LSP Location to jump to.
local function goto_location(location)
	textadept.history.record() -- store current position in jump history
	ui.goto_file(tofilename(location.uri), false, view)
	buffer:set_sel(tobufferrange(location.range))
	textadept.history.record() -- store new position in jump history
end

--- Jumps to the symbol selected from a list of LSP SymbolInformation or structures.
-- @param symbols List of LSP SymbolInformation or DocumentSymbol structures.
local function goto_selected_symbol(symbols)
	-- Prepare items for display in a list dialog.
	local items = {}
	for _, symbol in ipairs(symbols) do
		items[#items + 1] = symbol.name
		items[#items + 1] = symbol_kinds[symbol.kind]
		if not symbol.location then
			-- LSP DocumentSymbol has `range` instead of `location`.
			symbol.location = {
				uri = not WIN32 and buffer.filename or buffer.filename:gsub('\\', '/'), range = symbol.range
			}
		end
		items[#items + 1] = tofilename(symbol.location.uri)
	end
	-- Show the dialog and jump to the selected symbol.
	local i = ui.dialogs.list{
		title = 'Go To Symbol', columns = {'Name', 'Kind', 'Location'}, items = items
	}
	if i then goto_location(symbols[i].location) end
end

--- Jumps to a symbol selected from a list based on project symbols that match the given symbol,
-- or based on buffer symbols.
-- @param symbol Optional string symbol to query for in the current project. If `nil`, symbols
--	are presented from the current buffer.
function M.goto_symbol(symbol)
	local server = get_server()
	if not server or not buffer.filename then return end
	server:sync_buffer()
	local symbols
	if symbol and server.capabilities.workspaceSymbolProvider then
		-- Fetching project symbols that match the query.
		symbols = server:request('workspace/symbol', {query = symbol})
	elseif server.capabilities.documentSymbolProvider then
		-- Fetching symbols in the current buffer.
		symbols = server:request('textDocument/documentSymbol',
			{textDocument = {uri = touri(buffer.filename)}})
	end
	if symbols and #symbols > 0 then goto_selected_symbol(symbols) end
end

local snippets

local auto_c_incomplete = false
--- Autocompleter function for a language server.
-- @function _G.textadept.editing.autocompleters.lsp
textadept.editing.autocompleters.lsp = function()
	local server = get_server()
	if not (server and server.capabilities.completionProvider and (buffer.filename or
		(server.capabilities.experimental and
			server.capabilities.experimental.untitledDocumentCompletions))) then return end
	server:sync_buffer()
	-- Fetch a completion list.
	local completions = server:request('textDocument/completion', get_buffer_position_params())
	if not completions then return end
	auto_c_incomplete = completions.isIncomplete
	if auto_c_incomplete then ui.statusbar_text = _L['Note: completion list incomplete'] end
	if completions.items then completions = completions.items end
	if #completions == 0 then return end
	snippets = {}
	-- Associate completion items with icons.
	local symbols = {}
	for _, symbol in ipairs(completions) do
		local label = symbol.insertText or symbol.label
		if symbol.insertTextFormat == 2 then -- snippet
			label = symbol.filterText or symbol.label
			snippets[label] = symbol.insertText
		end
		-- TODO: some labels can have spaces and need proper handling.
		if symbol.kind and xpm_map[symbol.kind] > 0 then
			symbols[#symbols + 1] = string.format('%s?%d', label, xpm_map[symbol.kind]) -- TODO: auto_c_type_separator
		else
			symbols[#symbols + 1] = label
		end
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
	if server.auto_c_fill_ups ~= '' then buffer.auto_c_fill_ups = server.auto_c_fill_ups end
	return len_entered, symbols
end

local snippet_to_insert
-- Insert autocompletions as snippets and not plain text, if applicable.
events.connect(events.AUTO_C_COMPLETED, function(text, position, code)
	if not snippets then return end
	local snippet = snippets[text]
	snippets = nil
	if not snippet then return end
	snippet = snippet:sub(#text + 1 + (code ~= 0 and utf8.len(utf8.char(code)) or 0))
	if code == 0 then
		textadept.snippets.insert(snippet)
	else
		snippet_to_insert = snippet -- fill-up character will be inserted after this event
	end
end)
events.connect(events.CHAR_ADDED, function(code)
	if not snippet_to_insert then return end
	textadept.snippets.insert(snippet_to_insert) -- insert after fill-up character
	snippet_to_insert = nil
	return true -- other events may interfere with snippet insertion
end, 1)
events.connect(events.AUTO_C_CANCELED, function() snippets = nil end)

--- Requests autocompletion at the current position, returning `true` on success.
function M.autocomplete() return textadept.editing.autocomplete('lsp') end

--- Shows a calltip with information about the identifier at the given or current position.
-- @param position Optional buffer position of the identifier to show information for. If `nil`,
--	uses the current buffer position.
function M.hover(position)
	local server = get_server()
	if not (server and (buffer.filename or
		(server.capabilities.experimental and server.capabilities.experimental.untitledDocumentHover)) and
		server.capabilities.hoverProvider) then return end
	server:sync_buffer()
	local hover = server:request('textDocument/hover', get_buffer_position_params(position))
	if not hover then return end
	local contents = hover.contents
	if type(contents) == 'table' then
		-- LSP MarkedString[] or MarkupContent.
		for i, content in ipairs(contents) do
			if type(content) == 'table' then contents[i] = content.value end
		end
		contents = contents.value or table.concat(contents, '\n')
	end
	if not contents or contents == '' then return end
	view:call_tip_show(position or buffer.current_pos, contents)
end

--- Active call tip signatures.
-- @field activeSignature
-- @field activeParameter
-- @table signatures
-- @local
local signatures

local last_pos
--- Shows the currently active signature and highlights its current parameter if possible.
local function show_signature()
	local signature = signatures[(signatures.activeSignature or 0) + 1]
	if not view:call_tip_active() then last_pos = buffer.current_pos end
	view:call_tip_show(last_pos, signature.text)
	local params = signature.parameters
	if not params then return end
	local param = params[(signature.activeParameter or signatures.activeParameter or 0) + 1]
	local offset = #signatures == 1 and 1 or 2 -- account for Lua indices and cycle arrows
	if param and type(param.label) == 'table' then
		view:call_tip_set_hlt(param.label[1] + offset, param.label[2] + offset)
	end
end

--- Shows a calltip for the current function.
-- If a call tip is already shown, cycles to the next one if it exists unless specified otherwise.
-- @param no_cycle Flag that indicates to not cycle to the next call tip. This is used to update
--	the current highlighted parameter.
function M.signature_help(no_cycle)
	if view:call_tip_active() and signatures and #signatures > 1 and not no_cycle then
		events.emit(events.CALL_TIP_CLICK, 1)
		return
	end
	local server = get_server()
	if not (server and server.capabilities.signatureHelpProvider and (buffer.filename or
		(server.capabilities.experimental and
			server.capabilities.experimental.untitledDocumentSignatureHelp))) then return end
	server:sync_buffer()
	local params = get_buffer_position_params()
	if view:call_tip_active() then params.isRetrigger = true end
	local signature_help = server:request('textDocument/signatureHelp', params)
	if not signature_help or not signature_help.signatures or #signature_help.signatures == 0 then
		signatures = {} -- reset
		return
	end
	signatures = signature_help.signatures
	signatures.activeSignature = signature_help.activeSignature
	signatures.activeParameter = signature_help.activeParameter
	for _, signature in ipairs(signatures) do
		local doc = signature.documentation or ''
		-- Construct calltip text.
		if type(doc) == 'table' then doc = doc.value end -- LSP MarkupContent
		doc = string.format('%s\n%s', signature.label, doc)
		-- Wrap long lines in a rudimentary way.
		local lines, edge_column = {}, view.edge_column
		if edge_column == 0 then edge_column = not CURSES and 100 or 80 end
		for line in doc:gmatch('[^\n]+') do
			for j = 1, #line, edge_column do lines[#lines + 1] = line:sub(j, j + edge_column - 1) end
		end
		doc = table.concat(lines, '\n')
		-- Add arrow indicators for multiple signatures.
		if #signatures > 1 then doc = '\001' .. doc:gsub('\n', '\n\002', 1) end
		signature.text = doc
	end
	show_signature()
end

-- Cycle through signatures.
events.connect(events.CALL_TIP_CLICK, function(position)
	local server = get_server()
	if not (server and server.capabilities.signatureHelpProvider and signatures and
		signatures.activeSignature) then return end
	signatures.activeSignature = signatures.activeSignature + (position == 1 and -1 or 1)
	if signatures.activeSignature >= #signatures then
		signatures.activeSignature = 0
	elseif signatures.activeSignature < 0 then
		signatures.activeSignature = #signatures - 1
	end
	show_signature()
end)

-- Close the call tip when a trigger's complement is typed (e.g. ')').
events.connect(events.KEYPRESS, function(key)
	if not view:call_tip_active() then return end
	local server = get_server()
	if not server or not server.call_tip_triggers then return end
	for byte in pairs(server.call_tip_triggers) do
		if textadept.editing.auto_pairs[string.char(byte)] == key then
			view:call_tip_cancel()
			return
		end
	end
end, 1) -- needs to come before editing.lua's typeover character handler

--- Jumps to the declaration or definition of the current kind (e.g. symbol, type, interface),
-- returning whether or not a definition was found.
-- @param kind String LSP method name part after 'textDocument/' (e.g. 'declaration', 'definition',
--	'typeDefinition', 'implementation').
-- @return `true` if a declaration/definition was found; `false` otherwise
local function goto_definition(kind)
	local server = get_server()
	if not (server and buffer.filename and server.capabilities[kind .. 'Provider']) then return false end
	server:sync_buffer()
	local location = server:request('textDocument/' .. kind, get_buffer_position_params())
	if not location or not location.uri and #location == 0 then return false end
	if not location.uri then
		-- List of LSP Locations, instead of a single Location.
		if #location == 1 then
			location = location[1]
		else
			-- Select one from a list.
			local items = {}
			local root = io.get_project_root()
			for i = 1, #location do
				local filename = tofilename(location[i].uri)
				if root and filename:find(root, 1, true) then filename = filename:sub(#root + 2) end
				items[#items + 1] = filename
			end
			local title =
				(kind == 'declaration' and _L['Go To Declaration'] or _L['Go To Definition']):gsub('[_&]',
					'')
			local i = ui.dialogs.list{title = title, items = items}
			if not i then return true end -- definition found; user canceled
			location = location[i]
		end
	end
	goto_location(location)
	return true
end

--- Jumps to the declaration of the current symbol, returning whether or not a declaration
-- was found.
-- @return `true` if a declaration was found; `false` otherwise.
function M.goto_declaration() return goto_definition('declaration') end
--- Jumps to the definition of the current symbol, returning whether or not a definition was found.
-- @return `true` if a definition was found; `false` otherwise.
function M.goto_definition() return goto_definition('definition') end
--- Jumps to the definition of the current type, returning whether or not a definition was found.
-- @return `true` if a definition was found; `false` otherwise.
function M.goto_type_definition() return goto_definition('typeDefinition') end
--- Jumps to the implementation of the current symbol, returning whether or not an implementation
-- was found.
-- @return `true` if an implementation was found; `false` otherwise.
function M.goto_implementation() return goto_definition('implementation') end

--- Searches for project references to the current symbol and prints them like "Find in Files".
function M.find_references()
	local server = get_server()
	if not (server and buffer.filename and server.capabilities.referencesProvider) then return end
	server:sync_buffer()
	local params = get_buffer_position_params()
	params.context = {includeDeclaration = true}
	local locations = server:request('textDocument/references', params)
	if not locations or #locations == 0 then return end

	local line, pos = buffer:get_cur_line()
	local before, after = line:sub(1, pos - 1), line:sub(pos)
	local symbol = before:match('[%w_]*$') .. after:match('^[%w_]*') -- TODO: lang-specific chars
	local root = io.get_project_root()
	ui.print_to(_L['[Files Found Buffer]'],
		string.format('%s: %s\n%s %s', _L['Find References']:gsub('[_&]', ''), symbol, _L['Directory:'],
			root))
	buffer.indicator_current = ui.find.INDIC_FIND

	local orig_buffer, buffer = buffer, buffer.new()
	view:goto_buffer(orig_buffer)
	for _, location in ipairs(locations) do
		local filename = tofilename(location.uri)
		local f = io.open(filename, 'rb')
		buffer:target_whole_document()
		buffer:replace_target(f:read('a'))
		f:close()
		if filename:sub(1, #root) == root then filename = filename:sub(#root + 2) end
		local line_num = location.range.start.line + 1
		line = buffer:get_line(line_num)
		_G.buffer:add_text(string.format('%s:%d:%s', filename, line_num, line))
		local pos = _G.buffer.current_pos - #line + location.range.start.character
		_G.buffer:indicator_fill_range(pos,
			location.range['end'].character - location.range.start.character)
		if not line:find('\n$') then _G.buffer:add_text('\n') end
		buffer:clear_all()
		buffer:empty_undo_buffer()
		view:scroll_caret() -- [Files Found Buffer]
	end
	buffer:close(true) -- temporary buffer
	_G.buffer:new_line()
	_G.buffer:set_save_point()
end

--- Selects or expands the selection around the current position.
function M.select()
	local server = get_server()
	if not (server and buffer.filename and server.capabilities.selectionRangeProvider) then return end
	server:sync_buffer()
	local position = buffer.selection_empty and buffer.current_pos or
		buffer:position_before(buffer.selection_start)
	local line = buffer:line_from_position(position)
	local selections = server:request('textDocument/selectionRange', {
		textDocument = {uri = touri(buffer.filename)}, --
		positions = {{line = line - 1, character = position - buffer:position_from_line(line)}}
	})
	if not selections then return end
	local selection = selections[1]
	local s, e = tobufferrange(selection.range)
	if not buffer.selection_empty and s == buffer.selection_start and e == buffer.selection_end and
		selection.parent then s, e = tobufferrange(selection.parent.range) end
	buffer:set_sel(s, e)
end

--- Selects all instances of the symbol at the current position as multiple selections.
function M.select_all_symbol()
	local server = get_server()
	if not (server and buffer.filename and server.capabilities.linkedEditingRangeProvider) then
		return
	end
	server:sync_buffer()
	local ranges = server:request('textDocument/linkedEditingRange', get_buffer_position_params())
	if not ranges then return end
	ranges = ranges.ranges
	buffer:set_selection(tobufferrange(ranges[1]))
	for i = 2, #ranges do buffer:add_selection(tobufferrange(ranges[i])) end
end

-- Setup events to automatically start language servers and notify them as files are opened.
-- Connect to `events.FILE_OPENED` after initialization in order to not overwhelm LSP
-- connection when loading a session on startup. Connect to `events.BUFFER_AFTER_SWITCH` and
-- `events.VIEW_AFTER_SWITCH` in order to gradually notify the LSP of files opened from a session.
events.connect(events.INITIALIZED, function()
	local function start() if M.server_commands[buffer.lexer_language] then M.start() end end
	local function notify_opened()
		local server = get_server()
		if type(server) == 'table' then server:notify_opened() end
	end
	events.connect(events.LEXER_LOADED, start)
	events.connect(events.FILE_OPENED, notify_opened)
	events.connect(events.BUFFER_AFTER_SWITCH, notify_opened)
	events.connect(events.VIEW_AFTER_SWITCH, notify_opened)
	events.connect(events.RESET_AFTER, start)
	-- Automatically start language server for the current file, if possible.
	start()
end)

--- Synchronizes the current buffer with its language server if it is modified.
-- This allows for any unsaved changes to be reflected in another buffer.
local function sync_if_modified()
	local server = get_server()
	if server and buffer.filename and buffer.modify then server:sync_buffer() end
end
events.connect(events.BUFFER_BEFORE_SWITCH, sync_if_modified)
events.connect(events.VIEW_BEFORE_SWITCH, sync_if_modified)

-- Notify the language server when a buffer is saved.
events.connect(events.FILE_AFTER_SAVE, function(filename, saved_as)
	local server = get_server()
	if not server then return end
	if saved_as then
		server:notify_opened()
	else
		server:notify('textDocument/didSave', {
			textDocument = {uri = touri(filename), languageId = buffer.lexer_language, version = 0}
		})
	end
end)

-- Notify the language server when a file is closed.
events.connect(events.BUFFER_DELETED, function(buffer)
	if not buffer then return end -- older version of Textadept
	local server = get_server() -- buffer.lexer_language still exists thanks to rawset()
	if not server or not buffer.filename then return end
	server:notify('textDocument/didClose', {
		textDocument = {uri = touri(buffer.filename), languageId = buffer.lexer_language, version = 0}
	})
	server._opened[buffer.filename] = false -- TODO: server:notify_closed()?
end)

-- Show completions or signature help if a trigger character is typed.
events.connect(events.CHAR_ADDED, function(code)
	local server = get_server()
	if not server or code < 32 or code > 255 then return end
	if buffer:auto_c_active() then
		if M.show_completions and auto_c_incomplete then M.autocomplete() end -- re-trigger
		return
	end
	if M.show_signature_help and server.call_tip_triggers and server.call_tip_triggers[code] then
		M.signature_help(view:call_tip_active())
		if view:call_tip_active() then return end
	end
	if not M.show_completions then return end
	local trigger = server.auto_c_triggers[code] or (M.autocomplete_num_chars and buffer.current_pos -
		buffer:word_start_position(buffer.current_pos, true) >= M.autocomplete_num_chars)
	if trigger then M.autocomplete() end
end)

-- Query the language server for hover information when mousing over identifiers.
events.connect(events.DWELL_START, function(position)
	if position == 0 then return end -- Qt on Windows repeatedly sends this for some reason.
	if get_server() and M.show_hover then M.hover(position) end
end)
events.connect(events.DWELL_END, function() if get_server() then view:call_tip_cancel() end end)

--- Gracefully shut down servers on reset or quit.
local function shutdown_servers()
	for _, lang_servers in pairs(servers) do
		for _, server in pairs(lang_servers) do
			server:request('shutdown')
			server:notify('exit')
			servers[server.lang][server.root] = nil
		end
	end
end
events.connect(events.RESET_BEFORE, shutdown_servers) -- will be restarted as buffers are reloaded
events.connect(events.QUIT, shutdown_servers, 1)

-- Log buffer modification times for more real-time diagnostics.
local INSERT, DELETE = buffer.MOD_INSERTTEXT, buffer.MOD_DELETETEXT
events.connect(events.MODIFIED, function(position, mod)
	if mod & (INSERT | DELETE) > 0 then buffer._lsp_mod_time = os.time() end
end)

-- If the buffer has active diagnostics and has since been modified, ask the server for updated
-- diagnostics.
-- TODO: investigate using textDocument/diagnostic method and response. For now this is passive.
if not CURSES then
	timeout(1, function()
		if not buffer._lsp_diagnostic_time or not buffer._lsp_mod_time then return true end
		local server = get_server()
		if not server then return true end
		if buffer._lsp_mod_time > buffer._lsp_diagnostic_time then
			server:sync_buffer()
			buffer._lsp_mod_time, buffer._lsp_diagnostic_time = nil, nil
		end
		return true
	end)
end

-- Add a menu.
-- (Insert 'Language Server' menu in alphabetical order.)
local m_tools = textadept.menu.menubar['Tools']
local found_area
for i = 1, #m_tools - 1 do
	if not found_area and m_tools[i + 1].title == _L['Bookmarks'] then
		found_area = true
	elseif found_area then
		local label = m_tools[i].title or m_tools[i][1]
		if 'Language Server' < label:gsub('^_', '') or m_tools[i][1] == '' then
			table.insert(m_tools, i, {
				title = _L['Language Server'], {
					_L['Start Server...'], function()
						if get_server() then
							ui.dialogs.message{
								title = _L['Start Server...']:gsub('[_&]', ''),
								text = string.format('%s %s', buffer.lexer_language,
									_L['language server is already running'])
							}
							return
						end
						local cmd = ui.dialogs.input{
							title = string.format('%s %s', buffer.lexer_language,
								_L['language server shell command:']),
							text = M.server_commands[buffer.lexer_language]
						}
						if cmd and cmd ~= '' then M.start(cmd) end
					end
				}, {
					_L['Stop Server'], function()
						if not get_server() then return end
						local button = ui.dialogs.message{
							title = _L['Stop Server?'],
							text = string.format('%s %s?', _L['Stop the language server for'],
								buffer.lexer_language)
						}
						if button == 1 then M.stop() end
					end
				}, --
				{''}, {
					_L['Go To Workspace Symbol...'], function()
						if not get_server() then return end
						local query = ui.dialogs.input{title = _L['Symbol name or name part:']}
						if query and query ~= '' then M.goto_symbol(query) end
					end
				}, --
				{_L['Go To Document Symbol...'], M.goto_symbol}, --
				{_L['Autocomplete'], M.autocomplete}, {
					_L['Show Documentation'], function()
						local buffer, view = buffer, view
						if ui.command_entry.active then
							_G.buffer, _G.view = ui.command_entry, ui.command_entry
						end
						local cycle = view:call_tip_active()
						if not cycle then M.hover() end
						if not view:call_tip_active() or cycle then M.signature_help() end
						if ui.command_entry.active then _G.buffer, _G.view = buffer, view end
					end
				}, --
				{_L['Show Hover Information'], M.hover}, --
				{_L['Show Signature Help'], M.signature_help}, --
				{_L['Go To Declaration'], M.goto_declaration}, --
				{_L['Go To Definition'], M.goto_definition},
				{_L['Go To Type Definition'], M.goto_type_definition},
				{_L['Go To Implementation'], M.goto_implementation},
				{_L['Find References'], M.find_references}, --
				{_L['Select Around'], M.select}, --
				{_L['Select All Symbol'], M.select_all_symbol}, --
				{''}, {
					_L['Toggle Show Diagnostics'], function()
						M.show_diagnostics = not M.show_diagnostics
						if not M.show_diagnostics then buffer:annotation_clear_all() end
						ui.statusbar_text = M.show_diagnostics and _L['Showing diagnostics'] or
							_L['Hiding diagnostics']
					end
				}, --
				{''}, {
					_L['Show Log'], function()
						if #log_lines == 0 then return end
						if log_buffer and _BUFFERS[log_buffer] then
							for _, view in ipairs(_VIEWS) do
								if view.buffer == log_buffer then
									ui.goto_view(view)
									return
								end
							end
							view:goto_buffer(log_buffer)
							return
						end
						log_buffer = ui.print_to('[LSP]', table.concat(log_lines, '\n'))
					end
				}, --
				{_L['Clear Log'], function() log_lines = {} end}
			})
			break
		end
	end
end

keys['ctrl+ '] = M.autocomplete
if OSX then keys['cmd+ '] = M.autocomplete end
local show_documentation = textadept.menu.menubar['Tools/Language Server/Show Documentation'][2]
keys['ctrl+?'], ui.command_entry.editing_keys.__index['ctrl+?'] = show_documentation,
	show_documentation
if OSX or CURSES then
	keys[OSX and 'cmd+?' or 'meta+?'] = show_documentation
	ui.command_entry.editing_keys.__index[OSX and 'cmd+?' or 'meta+?'] = show_documentation
end
keys.f12 = M.goto_definition
keys['shift+f12'] = textadept.menu.menubar['Tools/Language Server/Go To Workspace Symbol...'][2]

-- Set up Lua LSP server to be Textadept running as a Lua interpreter with this module's server.
if arg then
	local ta = arg[0]:gsub('%.exe$', '')
	if not ta:find('%-curses$') then ta = ta:gsub('%-gtk$', '') .. '-curses' end -- run as background app
	if WIN32 then ta = ta .. '.exe' end
	if not lfs.attributes(ta) then ta = arg[0] end -- fallback
	M.server_commands.lua = string.format('"%s" -L "%s"', lfs.abspath(ta), package.searchpath('lsp',
		package.path):gsub('init%.lua$', 'server.lua'))
end
-- Save and restore Lua server command during reset since arg is nil.
events.connect(events.RESET_BEFORE, function(persist) persist.lsp_lua = M.server_commands.lua end)
events.connect(events.RESET_AFTER, function(persist) M.server_commands.lua = persist.lsp_lua end)

return M
