-- Copyright 2007-2023 Mitchell. See LICENSE.

--- Textadept autocompletions and API documentation filter/doclet for LDoc/LuaDoc.
-- This module is used by LDoc/LuaDoc to create Lua autocompletion and API documentation files
-- that the Lua LSP server can read.
-- To preserve formatting, the included *luadoc.patch* file must be applied to your instance
-- of LuaDoc. It will not affect the look of HTML web pages, only the look of plain-text output.
-- If the underlying LDoc/LuaDoc command contains a trailing `--root` option, symbol locations
-- within the given path will be written to output files as relative to that path. A `--multiple`
-- option writes one output file per Lua file scanned, as opposed to a single, large file.
-- @usage ldoc -d [output_path] --filter tadoc.ldoc [ldoc opts] [-- [--root="/path"] [--multiple]]
-- @usage luadoc -d [output_path] -doclet path/to/tadoc [file(s)] [--root="/path"] [--multiple]
-- @module tadoc
local M = {}

-- Parse command line options for defining non-LDoc/LuaDoc behavior.
local ROOT, multiple, output_dir
for i = 1, #arg do
	local root = arg[i]:match('^%-%-root="?([^"]-)"?$')
	if root then ROOT = root:gsub('%p', '%%%0') end
	if arg[i] == '--multiple' then multiple = true end
	if arg[i] == '-d' then output_dir = arg[i + 1] end
end

--- Writes a ctag.
-- @param file The file to write to.
-- @param name The name of the tag.
-- @param filename The filename the tag occurs in.
-- @param code The line of code the tag occurs on.
-- @param k The kind of ctag: m Module, f Function, l Local function, t Table, L Local table,
--	and F Field.
-- @param ext_fields The ext_fields for the ctag.
local function write_tag(file, name, filename, code, k, ext_fields)
	if ROOT then filename = filename:gsub(ROOT, '_ROOT') end
	if ext_fields == 'class:_G' then ext_fields = '' end
	file[#file + 1] = string.format('%s\t%s\t/^%s$/;"\t%s\t%s', name, filename, code, k, ext_fields)
end

--- Sanitizes Markdown from the given documentation string by stripping links and replacing
-- HTML entities.
-- @param s String to sanitize Markdown from.
-- @return string
local function sanitize_markdown(s)
	return s:gsub('%[([^%]\r\n]+)%]%b[]', '%1') -- [foo][]
	:gsub('%[([^%]\r\n]+)%]%b()', '%1') -- [foo](bar)
	:gsub('\r?\n\r?\n%[([^%]\r\n]+)%]:[^\r\n]+', '') -- [foo]: bar
	:gsub('\r?\n%[([^%]\r\n]+)%]:[^\r\n]+', '') -- [foo]: bar
	:gsub('&([%a]+);', {quot = '"', apos = "'"})
end

--- Writes a function or field apidoc.
-- @param file The file to write to.
-- @param m The LDoc/LuaDoc module object, or nil if the block object is local.
-- @param b The LDoc/LuaDoc block object.
local function write_apidoc(file, m, b)
	-- Function or field name.
	local name = b.name
	if not name:find('[.:]') then name = m and string.format('%s.%s', m.name, name) or name end
	name = name:gsub('^_G%.', '')
	-- Block documentation for the function or field.
	local doc = {}
	-- Function arguments or field type.
	local class = b.type or b.class
	local header = name
	if class:find('^l?function') then
		if class == 'lfunction' then header = 'local ' .. header end
		header = header ..
			(b.args or b.param and string.format('(%s)', table.concat(b.param, ', ')) or '()')
	elseif class == 'module' or class == 'table' then
		if class == 'table' and not m then header = 'local ' .. header end
		header = string.format('%s <%s>', header, class)
	elseif class == 'field' and not m then
		header = 'local ' .. header
	end
	doc[#doc + 1] = header
	-- Function or field description.
	local description = b.lineno and b.summary .. (b.description or '') or b.description -- ldoc has lineno
	-- Strip consistent leading whitespace.
	local indent = (b.description or ''):match('^[\r\n]*(%s*)')
	if indent ~= '' then description = description:gsub('\n' .. indent, '\n') end
	if class == 'module' then
		-- Modules usually have additional Markdown documentation so just grab the documentation
		-- before a Markdown header.
		description = description:match('^(.-)[\r\n]+%s*#') or description
	elseif class == 'field' then
		-- Type information is already in the header; discard it in the description.
		description = description:match('^%s*%b()[\t ]*[\r\n]*(.+)$') or description
	end
	doc[#doc + 1] = sanitize_markdown(description)
	-- Function parameters (@param).
	if class:find('^l?function') and (b.params or b.param) then
		for _, p in ipairs(b.params or b.param) do
			if b.params and b.params.map and #b.params.map[p] > 0 or
				(b.param and b.param[p] and #b.param[p] > 0) then
				doc[#doc + 1] = string.format('@param %s %s', p,
					sanitize_markdown(b.params and b.params.map[p] or b.param[p]))
			end
		end
	end
	-- Function usage (@usage).
	if class:find('^l?function') and b.usage then
		if type(b.usage) == 'string' then
			doc[#doc + 1] = '@usage ' .. b.usage
		elseif type(b.usage[1]) == 'string' then
			for _, u in ipairs(b.usage) do doc[#doc + 1] = '@usage ' .. u end
		end
	end
	-- Function returns (@return).
	if class == 'function' and b.ret then
		if type(b.ret) == 'string' then
			doc[#doc + 1] = '@return ' .. b.ret
		elseif type(b.ret[1]) == 'string' then
			for _, r in ipairs(b.ret) do doc[#doc + 1] = '@return ' .. r end
		end
	end
	-- See also (@see).
	if b.tags and b.tags.see or b.see then
		if type(b.see) == 'string' then
			doc[#doc + 1] = '@see ' .. b.see
		elseif type(b.tags and b.tags.see[1] or b.see and b.see[1]) == 'string' then
			for _, s in ipairs(b.tags and b.tags.see or b.see) do doc[#doc + 1] = '@see ' .. s end
		end
	end
	-- Format the block documentation.
	doc = table.concat(doc, '\n'):gsub('\\n', '\\\\n'):gsub('\n', '\\n')
	file[#file + 1] = string.format('%s %s', name:match('[^.:]+$'), doc)
end

--- Writes out the tags and api files.
-- @param tags Table of string tag lines.
-- @param apidoc Table of API documentation lines.
-- @param output_dir Directory to output tags and api files into.
-- @param filename Optional string filename prefix to tags and api files.
-- @param module_name Optional string module name prefix to tags and api files.
local function write_files(tags, apidoc, output_dir, filename, module_name)
	table.sort(tags)
	table.sort(apidoc)
	local prefix = output_dir .. '/'
	if filename then prefix = prefix .. filename .. '_' end
	if module_name then prefix = prefix .. module_name .. '_' end
	local f = io.open(prefix .. 'tags', 'wb')
	f:write(table.concat(tags, '\n'))
	f:close()
	f = io.open(prefix .. 'api', 'wb')
	f:write(table.concat(apidoc, '\n'))
	f:close()
end

--- Retrieves a symbol definition from the LDoc-reported line number.
-- LDoc typically returns the line after a doc comment, but if the doc comment is self-sufficient
-- (e.g. @module, @function, @table, etc.), look backwards and return a previous line.
-- @param lines List of lines in the file to search for a definition from.
-- @param lineno LDoc-provided line number of the symbol to search for.
local function find_line(lines, lineno)
	for i = math.min(lineno, #lines), 1, -1 do
		local line = lines[i]
		if not line:find('^%s*$') and not line:find('^%s*%-%-%-') then return line end
		if line:find('^%-%-%- @module') then return line end
	end
	return lines[lineno]
end

--- An LDoc filter function.
-- @param doc The LDoc doc object.
-- @usage ldoc --filter tadoc.ldoc [file or directory]
function M.ldoc(doc)
	local tags, apidoc = {}, {}
	for _, module in ipairs(doc) do
		-- Read the file by lines for putting definition text in tags files. (LDoc only contains
		-- line number info.)
		local lines = {}
		for line in io.lines(module.file) do lines[#lines + 1] = line end

		-- Tag and document the module.
		write_tag(tags, module.name:match('^[^.]+'), module.file, find_line(lines, module.lineno), 'm',
			'')
		if module.name:find('%.') then
			-- Tag the last part of the module as a table of the first part.
			local parent, child = module.name:match('^(.-)%.([^.]+)$')
			write_tag(tags, child, module.file, find_line(lines, module.lineno), 'm', 'class:' .. parent)
		end
		write_apidoc(apidoc, {name = '_G'}, module)

		-- Tag and document the functions, tables, and fields.
		for _, item in ipairs(module.items) do
			local module_name, item_name = module.name, item.name
			if item_name:find('[.:]') and item.modifiers['local'] then
				-- When table functions and methods are explicitly marked local, LDoc uses a
				-- fully-qualified name. Split it to be like other table functions and methods, but
				-- keep the local label.
				module_name, item_name = item_name:match('^(.+)[.:]([^.:]+)$')
				item.kind = 'class ' .. module_name
			elseif item_name:find('%.') then
				-- The field, table, or function has been named _G.name. Tag it as a global instead of
				-- in the current module.
				module_name, item_name = item_name:match('^_G%.(.-)%.?([^.]+)$')
				if not module_name then module_name, item_name = item.name:match('^(.-)%.([^.]+)$') end
				if not module_name or not item_name then
					print(string.format('%s:%d: [ERROR] Cannot determine module name for %s', module.file,
						module.lineno, item.name))
					module_name, item_name = module.name, item.name
				elseif module_name == '' then
					module_name = '_G'
				end
			end
			if item.type == 'function' then
				local class = item.kind:match('^class (%S+)')
				if not class and item_name:find(':') then class = item_name:match('^[^:]+') end
				write_tag(tags, item_name:match('[^:]+$'), module.file, find_line(lines, item.lineno), 'f',
					'class:' .. (class or module_name))
				write_apidoc(apidoc, module, item)
			elseif item.type == 'lfunction' then
				local class = item.kind:match('^class (%S+)') -- explicitly marked local
				write_tag(tags, item_name, module.file, find_line(lines, item.lineno), 'l',
					not class and '' or 'class:' .. class)
				write_apidoc(apidoc, nil, item)
			elseif item.type == 'table' then
				if not item.modifiers['local'] then
					write_tag(tags, item_name, module.file, find_line(lines, item.lineno), 't',
						'class:' .. module_name)
					write_apidoc(apidoc, module, item)
					item_name = string.format('%s.%s', module_name, item_name)
					for _, name in ipairs(item.params) do -- table fields
						write_tag(tags, name, module.file, find_line(lines, item.lineno), 'F',
							'class:' .. item_name)
						write_apidoc(apidoc, {name = item_name},
							{name = name, type = 'field', description = item.params.map[name]})
					end
				else
					write_tag(tags, item_name, module.file, find_line(lines, item.lineno), 'L', '')
					write_apidoc(apidoc, nil, item)
					for _, name in ipairs(item.params) do -- table fields
						write_tag(tags, name, module.file, find_line(lines, item.lineno), 'L',
							'class:' .. item_name)
						write_apidoc(apidoc, nil, {
							name = string.format('%s.%s', item_name, name), type = 'field',
							description = item.params.map[name]
						})
					end
				end
			elseif item.type == 'field' then
				write_tag(tags, item_name, module.file, find_line(lines, item.lineno), 'F',
					module_name ~= '' and 'class:' .. module_name or '')
				write_apidoc(apidoc, {name = module_name}, item)
			end
		end

		-- Write individual tags and api files if desired.
		if multiple then
			write_files(tags, apidoc, output_dir,
				module.file:gsub(ROOT .. '[/\\]', ''):gsub('[/\\.:]', '_'), module.name)
			tags, apidoc = {}, {}
		end
	end

	if not multiple then write_files(tags, apidoc, output_dir) end
end

--- Returns the absolute path of the given relative path.
-- @param path String relative path.
-- @return absolute path
local function abspath(path)
	if path:find('^/') then return path end
	path = string.format('%s/%s', require('lfs').currentdir(), path)
	path = path:gsub('%f[^/]%./', '') -- clean up './'
	while path:find('[^/]+/%.%./') do
		path = path:gsub('[^/]+/%.%./', '', 1) -- clean up '../'
	end
	return path
end

--- Called by LuaDoc to process a doc object.
-- @param doc The LuaDoc doc object.
function M.start(doc)
	local modules, files = doc.modules, doc.files

	-- Map doc objects to file names so a module can be mapped to its filename.
	for _, filename in ipairs(files) do
		local doc = files[filename].doc
		files[doc] = abspath(filename)
	end

	-- Add a module's fields to its LuaDoc.
	for _, filename in ipairs(files) do
		local module_doc = files[filename].doc[1]
		if module_doc and module_doc.class == 'module' and modules[module_doc.name] then
			modules[module_doc.name].fields = module_doc.field
		elseif module_doc then
			print(string.format('[WARN] %s has no module declaration', filename))
		end
	end

	-- Convert module functions in the Lua luadoc into LuaDoc modules.
	local lua_luadoc
	for _, filename in ipairs(files) do
		if filename:find('lua%.luadoc$') then
			lua_luadoc = files[filename]
			break
		end
	end
	if lua_luadoc and (#files == 1 or multiple) then
		for _, function_name in ipairs(lua_luadoc.functions) do
			local func = lua_luadoc.functions[function_name]
			local module_name = func.name:match('^([^.:]+)[.:]') or '_G'
			if not modules[module_name] then
				modules[#modules + 1] = module_name
				modules[module_name] = {name = module_name, functions = {}, doc = {{code = func.code}}}
				files[modules[module_name].doc] = abspath(files[1])
				-- For functions like file:read(), 'file' is not a module; fake it.
				if func.name:find(':') then modules[module_name].fake = true end
			end
			local module = modules[module_name]
			module.description = string.format('Lua %s module.', module.name)
			module.functions[#module.functions + 1] = func.name
			module.functions[func.name] = func
		end
		for _, table_name in ipairs(lua_luadoc.tables) do
			local table = lua_luadoc.tables[table_name]
			local module = modules[table.name or '_G']
			if not module.fields then module.fields = {} end
			local fields = module.fields
			for k, v in pairs(table.field) do
				if not tonumber(k) then fields[#fields + 1], fields[k] = k, v end
			end
		end
	end

	-- Process LuaDoc and write the tags and api files.
	local tags, apidoc = {}, {}
	for _, module_name in ipairs(modules) do
		local m = modules[module_name]
		local filename = files[m.doc]
		if not m.fake then
			-- Tag and document the module.
			write_tag(tags, m.name, filename, m.doc[1].code[1], 'm', '')
			if m.name:find('%.') then
				-- Tag the last part of the module as a table of the first part.
				local parent, child = m.name:match('^(.-)%.([^.]+)$')
				write_tag(tags, child, filename, m.doc[1].code[1], 'm', 'class:' .. parent)
			end
			m.class = 'module'
			write_apidoc(apidoc, {name = '_G'}, m)
		end
		-- Tag and document the functions.
		for _, function_name in ipairs(m.functions) do
			local module_name, name = function_name:match('^(.-)[.:]?([^.:]+)$')
			if module_name == '' then module_name = m.name end
			local func = m.functions[function_name]
			write_tag(tags, name, filename, func.code[1], 'f', 'class:' .. module_name)
			write_apidoc(apidoc, m, func)
		end
		if m.tables then
			-- Document the tables.
			for _, table_name in ipairs(m.tables) do
				local table = m.tables[table_name]
				local module_name = m.name
				if table_name:find('^_G%.') then
					module_name, table_name = table_name:match('^_G%.(.-)%.?([^.]+)$')
					if not module_name then
						print('[ERROR] Cannot determine module name for ' .. table.name)
					elseif module_name == '' then
						module_name = '_G' -- _G.keys or _G.snippets
					end
				end
				write_tag(tags, table_name, filename, table.code[1], 't', 'class:' .. module_name)
				write_apidoc(apidoc, m, table)
				if table.field then
					-- Tag and document the table's fields.
					table_name = string.format('%s.%s', module_name, table_name)
					for _, field_name in ipairs(table.field) do
						write_tag(tags, field_name, filename, table.code[1], 'F', 'class:' .. table_name)
						write_apidoc(apidoc, {name = table_name}, {
							name = field_name, description = table.field[field_name], class = 'table'
						})
					end
				end
			end
		end
		if m.fields then
			-- Tag and document the fields.
			for _, field_name in ipairs(m.fields) do
				local field = m.fields[field_name]
				local module_name = m.name
				if field_name:find('^_G%.') then
					module_name, field_name = field_name:match('^_G%.(.-)%.?([^.]+)$')
					if not module_name then
						print('[ERROR] Cannot determine module name for ' .. field.name)
					end
				end
				write_tag(tags, field_name, filename, m.doc[1].code[1], 'F', 'class:' .. module_name)
				write_apidoc(apidoc, {name = field_name}, {
					name = string.format('%s.%s', module_name, field_name), description = field,
					class = 'field'
				})
			end
		end
	end
	write_files(tags, apidoc, M.options.output_dir)
end

return M
