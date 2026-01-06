-- Copyright 2020-2026 Mitchell. See LICENSE.

local lsp = require('lsp')
events.emit(events.VIEW_NEW) -- register XPMs
lsp.log_rpc = true

teardown(function()
	lsp.stop()
	textadept.menu.menubar['Tools/Language Server/Show Log'][2]()
	if buffer._type == '[LSP]' then test.log('lsp log:\n\t', buffer:get_text():gsub('\n', '\n\t')) end
	textadept.menu.menubar['Tools/Language Server/Clear Log'][2]()
end)

local have_clangd = LINUX or OSX and not os.getenv('CI')

local clangd_project = {
	['.hg'] = {}, --
	['Foo.h'] = [[
#include <string>

class Foo {
public:
  Foo(const std::string& bar);
  const std::string& bar();

private:
  std::string mBar;
};
]], --
	['Foo.cpp'] = [[
#include "Foo.h"

Foo::Foo(const std::string& bar) : mBar(bar)
{}

const std::string& Foo::bar() {
  return mBar;
}
]], --
	['main.cpp'] = [[
#include "Foo.h"
#include <cstdio>

int main() {
  Foo foo("bar");
  printf("%s\n", foo.bar().c_str());
  return 0;
}
]], --
	Makefile = [[
all: main
main: main.cpp Foo.cpp ; $(CXX) -o $@ $^
clean: ; rm -f main
compile_commands.json:
        $(MAKE) clean
        bear $(MAKE)
]], --
	['compile_commands.json'] = [[
[
    {
        "arguments": [
            "g++",
            "-c",
            "-o",
            "main",
            "main.cpp"
        ],
        "directory": ".",
        "file": "main.cpp"
    },
    {
        "arguments": [
            "g++",
            "-c",
            "-o",
            "main",
            "Foo.cpp"
        ],
        "directory": ".",
        "file": "Foo.cpp"
    }
]
]]
}

test('lsp should start when opening a project file', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)

	io.open_file(dir / 'main.cpp')
	-- Ensure the language server starts. It normally autostarts, but this will not happen when
	-- the lsp module is loaded after init and was not able to hook into events.LEXER_LOADED,
	-- events.FILE_OPENED, etc.
	lsp.start()

	textadept.menu.menubar['Tools/Language Server/Show Log'][2]()
	test.wait(function() return buffer._type == '[LSP]' end)
	test.assert_contains(buffer:get_text(), 'Starting language server: clangd')
end)
if not have_clangd then skip('clangd is not available') end

test('lsp.goto_symbol should prompt to jump to a symbol in the current file', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()

	local select_first_item = test.stub(1)
	local _<close> = test.mock(ui.dialogs, 'list', select_first_item)

	lsp.goto_symbol()

	test.assert_equal(buffer:line_from_position(buffer.selection_start), 4)
	test.assert_contains(buffer:get_sel_text(), 'main()')
end)
if not have_clangd then skip('clangd is not available') end

test('lsp.autocomplete should show a list of completions', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(6, 28)) -- foo.bar().

	local auto_c_show = test.stub()
	local _<close> = test.mock(buffer, 'auto_c_show', auto_c_show)

	test.wait(function()
		lsp.autocomplete() -- this takes time to warm up for some reason
		return auto_c_show.called and auto_c_show.args[3]:find('append')
	end)
end)
if LINUX and CURSES then retry(1) end -- TODO: sometimes lsp.autocomplete() has nil message
if not have_clangd then skip('clangd is not available') end

test('lsp.hover should show a calltip with information for the current symbol', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer.line_indent_position[6]) -- printf

	local call_tip_show = test.stub()
	local _<close> = test.mock(view, 'call_tip_show', call_tip_show)

	lsp.hover()

	test.assert_equal(call_tip_show.called, true)
	test.assert_contains(call_tip_show.args[3], 'printf')
end)
if not have_clangd then skip('clangd is not available') end

test('lsp.signature_help should show a calltip for the current function', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(5, 11)) -- Foo foo(

	local call_tip_show = test.stub()
	local _<close> = test.mock(view, 'call_tip_show', call_tip_show)

	lsp.signature_help()

	test.assert_equal(call_tip_show.called, true)
	test.assert_contains(call_tip_show.args[3], 'Foo')
end)
if not have_clangd then skip('clangd is not available') end

test('lsp.signature_help should cycle through calltips', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(5, 11)) -- Foo foo(

	local call_tip_show = test.stub()
	local _<close> = test.mock(view, 'call_tip_show', call_tip_show)
	local call_tip_active = function() return call_tip_show.called end
	local _<close> = test.mock(view, 'call_tip_active', call_tip_active)

	lsp.signature_help()
	local calltip = call_tip_show.args[3]

	lsp.signature_help()
	test.assert(call_tip_show.args[3] ~= calltip, 'did not cycle calltip')

	-- Also verify menu item works.
	textadept.menu.menubar['Tools/Language Server/Show Documentation'][2]()
	test.assert(call_tip_show.args[3] ~= calltip, 'did not cycle calltip')
end)
if not have_clangd then skip('clangd is not available') end
if OSX then skip('calltip click is not implemented in Qt on macOS') end

test('lsp.goto_definition should jump to the definition of the current symbol', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer.line_indent_position[5]) -- Foo

	lsp.goto_definition()

	test.assert_equal(buffer.filename, dir / 'Foo.h')
	test.assert_equal(buffer:line_from_position(buffer.current_pos), 3)
	test.assert_equal(buffer:get_sel_text(), 'Foo')
end)
if not have_clangd then skip('clangd is not available') end

test('lsp.find_references should list project references for the current symbol', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(6, 25)) -- foo.bar

	lsp.find_references()

	test.assert_contains(buffer:get_text(), 'main.cpp:6: ')
	local highlights = test.get_indicated_text(ui.find.INDIC_FIND)
	test.assert_contains(highlights, 'bar')
end)
if not have_clangd then skip('clangd is not available') end

test('lsp.select should expand the selection around the current position', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(6, 12)) -- %s

	lsp.select()
	local first_selection = buffer:get_sel_text()
	lsp.select()
	local second_selection = buffer:get_sel_text()

	test.assert_equal(first_selection, '"%s\\n"')
	test.assert_equal(second_selection, 'printf("%s\\n", foo.bar().c_str())')
end)
if not have_clangd then skip('clangd is not available') end

test('lsp.select_all_symbol should select all instances of the current symbol', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(6, 20)) -- foo

	lsp.select_all_symbol()

	test.assert_equal(buffer.selections, 2)
	test.assert_equal(buffer:get_sel_text(), 'foofoo') -- Scintilla stores it this way
end)
expected_failure() -- clangd does not support this yet
if not have_clangd then skip('clangd is not available') end

test('lsp.code_action should pop up actions for selected text like an identifier', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(6, 25))
	textadept.editing.select_word() -- bar

	local user_list_show = test.stub()
	local _<close> = test.mock(buffer, 'user_list_show', user_list_show)

	lsp.code_action()

	test.assert_equal(buffer:get_sel_text(), 'bar')
	test.assert_equal(user_list_show.called, true)
	test.assert_contains(user_list_show.args[3], 'Extract subexpression to variable')
end)
if not have_clangd then skip('clangd is not available') end

test('typing should trigger lsp.autocomplete', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(6, 27)) -- foo.bar()
	buffer:line_end_extend()

	local autocomplete = test.stub()
	local _<close> = test.mock(lsp, 'autocomplete', autocomplete)

	test.type('.')

	test.assert_equal(autocomplete.called, true)
end)
if not have_clangd then skip('clangd is not available') end

test('hovering should trigger lsp.hover', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:line_end_extend()

	local hover = test.stub()
	local _<close> = test.mock(lsp, 'hover', hover)
	local call_tip_cancel = test.stub()
	local _<close> = test.mock(view, 'call_tip_cancel', call_tip_cancel)

	events.emit(events.DWELL_START, buffer.line_indent_position[6]) -- printf
	events.emit(events.DWELL_END)

	test.assert_equal(hover.called, true)
	test.assert_equal(call_tip_cancel.called, true)
end)
if not have_clangd then skip('clangd is not available') end

test('typing should trigger lsp.signature_help', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(5, 10)) -- Foo foo
	buffer:line_end_extend()

	local call_tip_show = test.stub()
	local _<close> = test.mock(view, 'call_tip_show', call_tip_show)

	test.type('(')

	test.assert_equal(call_tip_show.called, true)
	test.assert_contains(call_tip_show.args[3], 'Foo')
end)
if not have_clangd then skip('clangd is not available') end

test("typing ')' should cancel signature help", function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	lsp.start()
	buffer:goto_pos(buffer:find_column(5, 10)) -- Foo foo
	buffer:line_end_extend()

	local call_tip_show = test.stub()
	local _<close> = test.mock(view, 'call_tip_show', call_tip_show)
	local call_tip_active = function() return call_tip_show.called end
	local _<close> = test.mock(view, 'call_tip_active', call_tip_active)
	local call_tip_cancel = test.stub()
	local _<close> = test.mock(view, 'call_tip_cancel', call_tip_cancel)

	test.type('()')

	test.assert_equal(call_tip_cancel.called, true)
end)
if not have_clangd then skip('clangd is not available') end

test('clicking on a diagnostic and selecting a code action (if any) should run it', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')
	local orig_text = buffer:get_text()
	local pos = buffer:position_from_line(3)
	buffer:goto_pos(pos)
	buffer:add_text('#include <iostream>')
	buffer:new_line()
	lsp.start()

	local user_list_show = test.stub()
	local _<close> = test.mock(buffer, 'user_list_show', user_list_show)

	test.wait(function() return buffer:indicator_all_on_for(pos) > 0 end)
	-- Simulate click and selection.
	events.emit(events.INDICATOR_CLICK, pos)
	events.emit(events.USER_LIST_SELECTION, lsp.CODE_ACTION_ID, 'remove #include directive')

	test.wait(function() return buffer:get_text() == orig_text end)
end)
if OSX and not os.getenv('CI') then retry(1) end -- for some reason I need this
if not have_clangd then skip('clangd is not available') end
if have_clangd and LINUX and os.getenv('CI') == 'true' then skip('clangd diagnostics do not work') end

test('lua lsp should work for untitled buffers', function()
	buffer:set_lexer('lua')
	lsp.start()

	local auto_c_show = test.stub()
	local _<close> = test.mock(buffer, 'auto_c_show', auto_c_show)
	local call_tip_show = test.stub()
	local _<close> = test.mock(view, 'call_tip_show', call_tip_show)

	test.type('string.byte(')

	test.assert_equal(auto_c_show.called, true)
	test.assert_equal(call_tip_show.called, true)
end)

test('lua lsp should recognize M as the current module', function()
	local file = 'file.lua'
	local dir<close> = test.tmpdir{
		['.hg'] = {}, --
		[file] = [[
--- @module name
local M = {}

--- Field.
M.field = ''

--- Func.
function M.func() end
]]
	}
	io.open_file(dir / file)
	lsp.start()
	buffer:document_end()

	local auto_c_show = test.stub()
	local _<close> = test.mock(buffer, 'auto_c_show', auto_c_show)
	local call_tip_show = test.stub()
	local _<close> = test.mock(view, 'call_tip_show', call_tip_show)

	test.type('name.func(')

	test.assert_equal(auto_c_show.called, true)
	local completions = auto_c_show.args[3]
	test.assert_contains(completions, 'field')
	test.assert_contains(completions, 'func')
	test.assert_equal(call_tip_show.called, true)
end)
retry(1) -- TODO: for some reason this fails the first time

test('lsp menu should allow manually starting and stopping an lsp server', function()
	local _<close> = test.mock(lsp, 'server_commands', {cpp = 'clangd'})
	local dir<close> = test.tmpdir(clangd_project)
	io.open_file(dir / 'main.cpp')

	local clangd = 'clangd'
	local provide_clangd = test.stub(clangd)
	local _<close> = test.mock(ui.dialogs, 'input', provide_clangd)

	textadept.menu.menubar['Tools/Language Server/Start Server...'][2]()
	textadept.menu.menubar['Tools/Language Server/Show Log'][2]()
	test.wait(function() return buffer._type == '[LSP]' end)
	local lsp_log = buffer:get_text()
	buffer:close()

	local already_running_message = test.stub()
	local _<close> = test.mock(ui.dialogs, 'message', already_running_message)

	textadept.menu.menubar['Tools/Language Server/Start Server...'][2]()

	local confirm_stop = test.stub(1)
	local _<close> = test.mock(ui.dialogs, 'message', confirm_stop)

	textadept.menu.menubar['Tools/Language Server/Stop Server'][2]()

	test.assert_equal(provide_clangd.called, true)
	local dialog_opts = provide_clangd.args[1]
	test.assert_equal(dialog_opts.text, clangd)
	test.assert_contains(lsp_log, 'Starting language server: ' .. clangd)

	test.assert_equal(already_running_message.called, true)
	test.assert_equal(confirm_stop.called, true)
end)
if not have_clangd then skip('clangd is not available') end

test('Lua command entry should load and show Textadept documentation', function()
	local call_tip_show = test.stub()
	local _<close> = test.mock(ui.command_entry, 'call_tip_show', call_tip_show)
	local call_tip_active = function() return call_tip_show.called end
	local _<close> = test.mock(ui.command_entry, 'call_tip_active', call_tip_active)
	rawset(ui.command_entry, 'active', true) -- note: cannot mock
	local _<close> = test.defer(function() rawset(ui.command_entry, 'active', nil) end)
	local _<close> = test.mock(ui.command_entry, 'lexer_language', 'lua')
	ui.command_entry:set_text('auto_c_show')

	textadept.menu.menubar['Tools/Language Server/Show Documentation'][2]()

	test.assert_equal(call_tip_show.called, true)
	test.assert_contains(call_tip_show.args[3], 'auto_c_show')
end)
