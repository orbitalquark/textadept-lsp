#!/bin/env lua
-- Copyright 2023 Mitchell. See LICENSE.

--- Simple Lua language server for developing with Lua and Textadept.
-- @module lsp.server

local WIN32 = package.path:find('\\')

local lfs = require('lfs')
local dir = arg[0]:match('^(.+)[/\\]') or '.'
lfs.chdir(dir) -- cd to this directory
local ldoc = arg[-2] and string.format('"%s" -L "%s/ldoc.lua"', arg[-2], dir) or 'ldoc'
package.path = string.format('%s/?.lua;%s/?/init.lua;%s', dir, dir, package.path)
local userhome = os.getenv(not WIN32 and 'HOME' or 'USERPROFILE') .. '/.textadept'
local logfile = userhome .. '/lua_lsp_server.log'
io.open(logfile, 'w'):close() -- clear previous log

local json = require('dkjson')
local pl_dir = require('pl.dir')
local log = require('logging.file') {filename = logfile, logPattern = '%level: %message\n'}

log:setLevel(log.INFO)

--- Read a request or notification from the LSP client.
-- @return JSON RPC object received
local function read()
	log:debug('Waiting for client message...')
	local line = io.read()
	while not line:find('^\n?Content%-Length: %d+') do line = io.read() end
	local len = tonumber(line:match('%d+'))
	-- while #line > 0 do line = io.read() end -- skip other headers
	local data = io.read(len)
	log:debug('Recv: %s', data)
	return json.decode(data)
end

--- Respond to an LSP client request.
-- @param id ID of the client request being responded to.
-- @param result Table object to send.
local function respond(id, result)
	local key = not (result.code and result.message) and 'result' or 'error'
	local message = {jsonrpc = '2.0', id = id, [key] = result}
	local content = json.encode(message)
	log:debug('Send: %s', content)
	io.write(string.format('Content-Length: %d\r\n\r\n%s\r\n', #content + 2, content)):flush()
end

local root, options, client_capabilities, cache, tags, api
local files = {} -- map of open file URIs to their content lines
local handlers = {} -- LSP method and notification handlers

--- Registers function *f* as the handler for the LSP method named *method*.
-- Requests must return either an object to respond with or `json.null`.
-- Notifications must not return anything at all (`nil`).
-- @param method String LSP method name to handle.
-- @param f Method handler function.
local function register(method, f) handlers[method] = f end

--- Converts the given LSP DocumentUri into a valid filename and returns it.
-- @param uri LSP DocumentUri to convert into a filename.
local function tofilename(uri)
	local filename = uri:gsub(not WIN32 and '^file://' or '^file:///', '')
	filename = filename:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
	if WIN32 then filename = filename:gsub('/', '\\') end
	if filename == 'untitled:' then filename = 'untitled' end
	return filename
end

--- Converts the given filename into a valid LSP DocumentUri and returns it.
-- @param filename String filename to convert into an LSP DocumentUri.
local function touri(filename)
	return not WIN32 and 'file://' .. filename or 'file:///' .. filename:gsub('\\', '/')
end

-- LSP initialize request.
register('initialize', function(params)
	local uri = params.workspaceFolders and params.workspaceFolders[1].uri or params.rootUri or
		params.rootPath
	if uri then root = tofilename(uri) end
	cache = os.tmpname()
	os.remove(cache) -- Linux creates this file
	lfs.mkdir(cache)
	pl_dir.copyfile('tadoc.lua', cache .. '/tadoc.lua')
	log:info('Initialize (root=%s, cache=%s)', root or 'nil', cache)
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
			signatureHelpProvider = {triggerCharacters = {'(', '{', ','}, retriggerCharacters = {','}},
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
				untitledDocumentSignatureHelp = true, -- custom for this server
				untitledDocumentHover = true -- custom for this server
			}
		}
		-- serverInfo = 'Textadept'
	}
end)

-- LSP initialized notification.
register('initialized', function() end) -- no-op

--- Scans directory or file *target* and caches the result.
-- @param target String directory or file path.
local function scan(target)
	log:debug('Scanning %s', target)

	-- Determine files to scan.
	local files = {}
	if lfs.attributes(target, 'mode') == 'directory' then
		log:debug('Directory detected')

		-- Read config.
		local config_file, config = target .. '/.lua-lsp', {
			ignore = {'*.hg', '*.git', '*.bzr', '*.svn', '*_FOSSIL_', '*node_modules'}, max_scan = 10000
		}
		if lfs.attributes(config_file) then
			log:debug('Reading config in %s', config_file)
			local ok, errmsg = pcall(assert(loadfile(target .. '/.lua-lsp', 't', config)))
			if not ok then log:warn('Config error: %s', errmsg) end
		end
		log:debug(function() return 'config = ' .. require('pl.pretty').write(config, '') end)

		-- Walk the directory, looking for files to scan.
		local fnmatch = pl_dir.fnmatch
		local total_files_seen = 0
		local function walk(dir)
			log:debug('Identifying files to scan in %s', dir)
			for _, path in ipairs(pl_dir.getdirectories(dir)) do
				if config.ignore then
					for _, ignore in ipairs(config.ignore) do
						if fnmatch(path:sub(#target + 2), ignore) then goto continue end
					end
				end
				walk(path)
				if total_files_seen > config.max_scan then
					log:warn('Directory too large to scan (more than %d files)', config.max_scan)
					return
				end
				::continue::
			end
			local seen = #files
			for _, path in ipairs(pl_dir.getfiles(dir)) do
				if path:find('%.luad?o?c?$') then files[#files + 1] = path end
				total_files_seen = total_files_seen + 1
			end
			if #files > seen then log:debug('Identified %s files in %s', #files - seen, dir) end
		end
		walk(target)
	else
		log:debug('File detected')
		files[1] = target
	end
	log:debug('Identified a total of %d files to scan', #files)
	if #files == 0 then return end

	-- Write LDoc config.
	local config = cache .. '/config.ld'
	local f = assert(io.open(config, 'wb'))
	local dump = require('pl.pretty').write(files)
	f:write('file=', dump, '\n', 'custom_see_handler(".+", function(s) return s, s end)'):close()
	log:debug('Wrote config file: %s\nfile=%s', config, dump)

	-- Invoke LDoc.
	local command = string.format(
		'%s -d "%s" -c "%s" . --filter tadoc.ldoc --all -- --root="%s" --multiple', ldoc, cache, config,
		target)
	if WIN32 then command = '"' .. command .. '"' end -- quote for os.execute()'s "cmd /C [command]"
	log:debug('Running scan command: %s', command)
	os.execute(command)

	-- Register results.
	tags, api = pl_dir.getfiles(cache, '*_tags'), pl_dir.getfiles(cache, '*_api')
	log:debug('Read cache: #tags=%d #api=%d', #tags, #api)
end

local _HOME = os.getenv('TEXTADEPT_HOME') or (arg[-2] and arg[-2]:match('^.+[/\\]'))
local scanned_textadept = false
-- LSP textDocument/didOpen notification.
register('textDocument/didOpen', function(params)
	local lines = {}
	for line in params.textDocument.text:gmatch('[^\n]*\n?') do lines[#lines + 1] = line end
	files[params.textDocument.uri] = lines
	log:debug('Cached the lines of %s', params.textDocument.uri)

	if params.textDocument.uri:find('[/\\]%.?textadept[/\\]') and not scanned_textadept and _HOME then
		scanned_textadept = true
		scan(_HOME)
	end
end)

register('textDocument/didClose', function() end)
register('textDocument/didSave', function() end)

local tmpfiles = {} -- holds the prefixes for temporary file scan results
-- LSP textDocument/didChange notification.
register('textDocument/didChange', function(params)
	if tmpfiles[params.textDocument.uri] then
		local tmpfile = tmpfiles[params.textDocument.uri]
		log:debug('Removing temporary scan results from cache: %s*', tmpfile)
		for file in lfs.dir(cache) do
			if file:find(tmpfile, 1, true) then os.remove(cache .. '/' .. file) end
		end
		tmpfiles[params.textDocument.uri] = nil
	end

	local lines = {}
	for line in params.contentChanges[1].text:gmatch('[^\n]*\n?') do lines[#lines + 1] = line end
	files[params.textDocument.uri] = lines
	log:debug('Cached the contents of %s', params.textDocument.uri)
	-- Scan it, but with a path relative to a temporary root directory.
	-- This allows "Go to Definition" to function correctly for files with unsaved changes.
	local tmpdir = os.tmpname()
	os.remove(tmpdir) -- Linux creates this file
	local filename = tofilename(params.textDocument.uri)
	if root and filename:sub(1, #root) == root then filename = filename:sub(#root + 2) end
	if WIN32 then filename = filename:gsub('^%a:', '') end
	log:debug('Preparing to scan: %s (relative path=%s)', tofilename(params.textDocument.uri),
		filename)
	local path = tmpdir .. '/' .. filename
	pl_dir.makepath(path:match('^.+[/\\]'))
	log:debug('Creating temporary file: %s', filename)
	io.open(path, 'wb'):write(params.contentChanges[1].text):close()
	scan(tmpdir)
	tmpfiles[params.textDocument.uri] = tmpdir:gsub('[/\\]', '_') -- tadoc saves files like this
	pl_dir.rmtree(tmpdir)
end)

--- Map of expression patterns to their types.
-- Used for type-hinting when showing autocompletions for variables. Expressions are expected
-- to match after the '=' sign of a statement.
-- @usage expr_types['^spawn%b()%s*$'] = 'proc'
local expr_types = {['^[\'"]'] = 'string', ['^io%.p?open%s*%b()%s*$'] = 'file'}

--- Map of tags kinds to LSP CompletionItemKinds.
local kinds = {m = 7, f = 3, F = 5, t = 8, l = 3, L = 6}

-- LSP textDocument/completion request.
-- Uses the text previously sent via textDocument/didChange to determine the symbol at the
-- given completion position.
register('textDocument/completion', function(params)
	local items = {}

	-- Retrieve the symbol behind the caret.
	local filename = tofilename(params.textDocument.uri)
	local line_num, col_num = params.position.line + 1, params.position.character + 1
	local lines = files[params.textDocument.uri]
	local symbol, op, part = lines[line_num]:sub(1, col_num - 1):match('([%w_%.]-)([%.:]?)([%w_]*)$')
	log:debug('Get completions at %s:%d:%d: symbol=%s op=%s part=%s', filename, line_num, col_num,
		symbol, op, part)
	if symbol == '' and part == '' then return json.null end -- nothing to complete
	symbol, part = symbol:gsub('^_G%.?', ''), part ~= '_G' and part or ''
	-- Attempt to identify string type and file type symbols.
	local assignment = '%f[%w_]' .. symbol:gsub('(%p)', '%%%1') .. '%s*=%s*(.*)$'
	for i = line_num - 1, 1, -1 do
		local expr = lines[i]:match(assignment)
		if not expr then goto continue end
		for patt, type in pairs(expr_types) do
			if expr:find(patt) then
				log:debug('Inferred type of %s (%s); using it instead', symbol, type)
				symbol = type
				break
			end
		end
		::continue::
	end

	-- Search through tags for completions for that symbol.
	log:debug('Searching for completions in cache')
	local name_patt, seen = '^' .. part, {}
	for _, tag_file in ipairs(tags) do
		if not tag_file or not lfs.attributes(tag_file) then goto continue end
		for line in io.lines(tag_file) do
			local name, src_file = line:match('^(%S+)%s+([^\t]+)')
			if not name:find(name_patt) or seen[name] then goto continue end
			local fields = line:match(';"\t(.*)$')
			if part ~= '' then
				-- When part == '', every symbol is a candidate, so there's no point in logging that.
				log:debug('Found candidate: (name=%s file=%s fields=%s)', name, tag_file, fields)
			end
			local k, class = fields:sub(1, 1), fields:match('class:(%S+)') or ''
			if class == symbol and (op ~= ':' or k == 'f' or k == 'l') then
				if (k == 'l' or k == 'L') and filename ~= src_file:gsub('^_ROOT', root or '') then
					goto continue -- only allow for local completions in the same file
				end
				log:debug('Found completion: %s (file=%s fields=%s)', name, tag_file, fields)
				items[#items + 1], seen[name] = {label = name, kind = kinds[k]}, true
			end
			::continue::
		end
		::continue::
	end

	log:debug('Found %d completions', #items)
	return items
end)

--- Returns the symbol at a text document position.
-- @param params LSP TextDocumentPositionParams object.
-- @return symbol or nil
local function get_symbol(params)
	local line_num, col_num = params.position.line + 1, params.position.character + 1
	local line = files[params.textDocument.uri][line_num]
	local symbol_part_right = line:match('^[%w_]*', col_num)
	local symbol_part_left = line:sub(1, col_num - 1):match('[%w_.:]*$')
	local symbol = symbol_part_left .. symbol_part_right
	return symbol ~= '' and symbol or nil
end

--- Returns a list of API docs for the given symbol.
-- @param symbol String symbol get get API docs for.
-- @param filename String filename containing the given symbol.
-- @return list of documentation strings
local function get_api(symbol, filename)
	log:debug('Searching cache for documentation about %s', symbol)
	local docs = {}
	local symbol_patt, full_patt = '^' .. symbol:match('[%w_]+$'), '^' .. symbol:gsub('%p', '%%%0')
	for _, api_file in ipairs(api) do
		if not api_file or not lfs.attributes(api_file) then goto continue end
		local api_src -- the source file this API file was generated from
		for line in io.lines(api_file) do
			if not line:find(symbol_patt) then goto continue end
			log:debug('Found candidate: (name=%s file=%s)', line:match('^%S+'), api_file)
			local doc = line:match(symbol_patt .. '%s+(.+)$')
			if not doc then goto continue end
			local full_match = doc:find(full_patt)
			if not full_match and doc:find('^local ') then
				-- Reject the local candidate if it is not within the current file.
				if not api_src then
					-- Determine the candidate's file from its companion tags file's contents.
					local ok, f = pcall(io.open, (api_file:gsub('_api$', '_tags')))
					if ok then
						api_src = f:read():match('^%S+%s+([^\t]+)'):gsub('^_ROOT', ''):gsub('%p', '%%%0') .. '$'
						f:close()
					else
						api_src = ''
					end
				end
				if api_src == '' or not filename:find(api_src) then
					log:debug('Local candidate rejected (not in %s)', api_src)
					goto continue
				end
				full_match = doc:gsub('^local ', ''):find(full_patt)
			end
			log:debug(full_match and 'Confirmed' or 'Fuzzy match')
			docs[#docs + 1] = doc:gsub('%f[\\]\\n', '\n'):gsub('\\\\', '\\')
			if full_match then return {docs[#docs]} end
			::continue::
		end
		::continue::
	end
	log:debug('Found %d documentation items', #docs)
	return docs
end

-- LSP textDocument/hover request.
register('textDocument/hover', function(params)
	local symbol = get_symbol(params)
	if not symbol then return json.null end
	log:debug('Hover: %s', symbol)
	local docs = get_api(symbol, tofilename(params.textDocument.uri))
	return #docs > 0 and {contents = {kind = 'plaintext', value = docs[1]}} or json.null
end)

-- LSP textDocument/signatureHelp request.
register('textDocument/signatureHelp', function(params)
	local signatures = {}

	-- Retrieve the function behind the caret.
	local filename = tofilename(params.textDocument.uri)
	local line_num, col_num = params.position.line + 1, params.position.character + 1
	local lines, prev_lines = files[params.textDocument.uri], {}
	for i = 1, line_num - 1 do prev_lines[#prev_lines + 1] = lines[i] end
	local text, pos = table.concat(lines), #table.concat(prev_lines) + col_num - 1
	log:debug('Get signature at %s:%d:%d (pos=%d)', filename, line_num, col_num, pos)
	local s = pos
	local active_param = not text:find('^,', s) and 1 or 2
	::retry::
	while s > 1 and not text:find('^[({]', s) do
		s = s - 1
		if text:find('^,', s) then active_param = active_param + 1 end
	end
	local e = select(2, text:find('^%b()', s)) or select(2, text:find('^%b{}', s))
	if e and e < pos then
		log:debug('Skipping previous () or {} (s=%d e=%d)', s, e)
		s = s - 1
		if text:find('^{', s) then active_param = 1 end -- was inside table arg, so reset param count
		goto retry
	end
	local func = text:sub(1, s - 1):match('[%w_.:]+$')
	if not func then return json.null end

	-- Get its signature(s).
	for _, doc in ipairs(get_api(func, filename)) do
		local parameters = {}
		pos = doc:find('%b()')
		if pos then
			pos = pos - 1
			for s, e in doc:match('%b()'):gmatch('()[^(),]+()') do
				parameters[#parameters + 1] = {label = {pos + s - 1, pos + e - 1}}
			end
		end
		local doc_func = doc:match('([%w_.:]+)%b()') or ''
		signatures[#signatures + 1] = {
			label = doc, parameters = parameters,
			activeParameter = active_param + (func:find(':') and not doc_func:find(':') and 1 or 0) - 1
		}
	end
	return {signatures = signatures, activeSignature = 0, activeParameter = active_param - 1}
end)

-- LSP textDocument/definition request.
register('textDocument/definition', function(params)
	local locations = {}

	-- Retrieve the symbol at the caret.
	local symbol = get_symbol(params)
	if not symbol then return json.null end

	-- Search through tags for that symbol.
	log:debug('Searching cache for definition of %s', symbol)
	local patt = '^(' .. symbol:match('[%w_]+$') .. ')\t([^\t]+)\t(.-);"\t?(.*)$'
	for _, filename in ipairs(tags) do
		if not filename or not lfs.attributes(filename) then goto continue end
		for tag_line in io.lines(filename) do
			local name, file, ex_cmd, ext_fields = tag_line:match(patt)
			if not name then goto continue end
			if root then file = file:gsub('^_ROOT', root) end
			log:debug('Found candidate: %s (file=%s)', ex_cmd, filename)
			local uri = touri(file)
			ex_cmd = ex_cmd:match('/^?(.-)$?/$')
			if files[uri] then
				-- Find definition in cached file.
				for i, line in ipairs(files[uri]) do
					local s, e = line:find(ex_cmd, 1, true)
					if not s and not e then goto continue end
					log:debug('Confirmed in cached file, line %d', i - 1)
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
			if not lfs.attributes(file) then goto continue end
			for line in io.lines(file) do
				local s, e = line:find(ex_cmd, 1, true)
				if s and e then
					log:debug('Confirmed in file on disk, line %d', i - 1)
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
	log:info('Shutting down')
	pl_dir.rmtree(cache)
	log:debug('Cleaned up')
	return json.null
end)

-- Main server loop.
log:info('Starting up')
local message = read()
while message.method ~= 'exit' do
	local ok, result = xpcall(handlers[message.method], function(errmsg)
		errmsg = debug.traceback(errmsg)
		log:error(string.format('%s\n%s', json.encode(message), errmsg))
		return {code = 1, message = errmsg}
	end, message.params)
	if result then respond(message.id, result) end
	if message.method == 'initialize' then
		if root then scan(root) end
		scan(lfs.currentdir() .. '/doc') -- Lua stdlib
	end
	message = read()
end
log:info('Exiting')
