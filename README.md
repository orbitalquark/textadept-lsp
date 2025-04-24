# Language Server Protocol

A client for Textadept that communicates over the [Language Server Protocol][] (LSP) with
language servers in order to provide autocompletion, calltips, go to definition, and more.

It implements version 3.17.0 of the protocol, but does not support all protocol features. The
`Server.new()` function contains the client's current set of capabilities.

Install this module by copying it into your *~/.textadept/modules/* directory or Textadept's
*modules/* directory, and then putting the following in your *~/.textadept/init.lua*:

```lua
local lsp = require('lsp')
```

You can then set up some language server commands. For example:

```lua
lsp.server_commands.cpp = 'clangd'
lsp.server_commands.go = 'gopls'
```

(For more example configurations, see the [wiki][].)

When either C++ or Go files are opened, their associated language servers are automatically
started (one per project). Note that language servers typically require a root URI, so this
module uses `io.get_project_root()` for this. If the file being opened is not part of a
project recognized by Textadept, the language server will not be started.

Language Server features are available from the Tools > Language Server menu. Note that not
all language servers may support the menu options.

> [!NOTE]
> If you want to inspect the LSP messages sent back and forth, you can use the Lua command
> entry to set `require('lsp').log_rpc = true`. It doesn't matter if any LSPs are already
> active -- from this point forward all messages will be logged. View the log via the "Tools >
> Language Server > View Log" menu item.

> [!WARNING]
> Buggy language servers that do not respect the protocol may cause this module and Textadept
> to hang, waiting for a response. There is no recourse other than to force-quit Textadept
> and restart.

[Language Server Protocol]: https://microsoft.github.io/language-server-protocol/specification
[wiki]: https://github.com/orbitalquark/textadept/wiki/LSP-Configurations

## Lua Language Server

This module comes with a simple Lua language server that starts up when Textadept opens a
Lua file, or whenever you request documentation for a symbol in the Lua command entry. The
server looks in the project root for a *.lua-lsp* configuration file. That file can have
the following fields:

- `ignore`: List of globs that match directories and files to ignore. Globs are relative to
	the project root. The default directories ignored are .bzr, .git, .hg, .svn, _FOSSIL_,
	and node_modules. Setting this field overrides the default.
- `max_scan`: Maximum number of files to scan before giving up. This is not the number of
	Lua files scanned, but the number of files encountered in non-ignored directories.
	The primary purpose of this field is to avoid hammering the disk when accidentally
	opening a large project or root. The default value is 10,000.

For example:

```lua
ignore = {'.git', 'build', 'test'}
max_scan = 20000
```

## Key Bindings

Windows and Linux | macOS | Terminal | Command
-|-|-|-
**Tools**| | |
Ctrl+Space | ⌘Space<br/> ^Space | ^Space | Complete symbol
Ctrl+? | ⌘?<br/>^? | M-?<br/>Ctrl+?<sup>‡</sup> | Show documentation
F12 | F12 | F12 | Go To Definition
Shift+F12 | ⇧F12 | Shift+F12 | Go to Symbol...

‡: Windows terminal version only.

<a id="lsp.CODE_ACTION_ID"></a>
## `lsp.CODE_ACTION_ID`

The code action user list number.

<a id="events.LSP_INITIALIZED"></a>
## `events.LSP_INITIALIZED`

Emitted when an LSP connection has been initialized.

This is useful for sending server-specific notifications to the server upon init via
`Server:notify()`.

Arguments:
- *lang*: The lexer name of the LSP language.
- *server*: The LSP server.

See also: [`lsp.start`](#lsp.start)

<a id="events.LSP_NOTIFICATION"></a>
## `events.LSP_NOTIFICATION`

Emitted when an LSP server emits an unhandled notification.

This is useful for handling server-specific notifications.

An event handler should return `true`.

Arguments:
- *lang*: The lexer name of the LSP language.
- *server*: The LSP server.
- *method*: The string LSP notification method name.
- *params*: The table of LSP notification params. Contents may be server-specific.

<a id="events.LSP_REQUEST"></a>
## `events.LSP_REQUEST`

Emitted when an LSP server emits an unhandled request.

This is useful for handling server-specific requests. Responses are sent using
`Server:respond()`.

An event handler should return `true`.

Arguments:
- *lang*: The lexer name of the LSP language.
- *server*: The LSP server.
- *id*: The integer LSP request ID.
- *method*: The string LSP request method name.
- *params*: The table of LSP request params.

<a id="_G.textadept.editing.autocompleters.lsp"></a>
## `_G.textadept.editing.autocompleters.lsp`()

Autocompleter function for a language server.

<a id="lsp.autocomplete"></a>
## `lsp.autocomplete`()

Requests autocompletion at the current position.

Returns: `true` if autocompletions were shown; `nil` otherwise

<a id="lsp.autocomplete_num_chars"></a>
## `lsp.autocomplete_num_chars`

The number of characters typed after which autocomplete is automatically triggered.

The default value is `nil`, which disables this feature. A value greater than or equal to
3 is recommended to enable this feature.

<a id="lsp.code_action"></a>
## `lsp.code_action`([*s*[, *e*]])

Requests a list of code actions for the a range and prompts the user with a user list to
select from.

Parameters:
- *s*:  Start position of the code action range. If omitted, the start of the current
	selection is used, or the start of the line if no text is selected.
- *e*:  End position of the code action range. If omitted, the end of the current
	selection is used, or the end of the line if no text is selected.

<a id="lsp.find_references"></a>
## `lsp.find_references`()

Searches for project references to the current symbol and prints them like "Find in Files" does.

<a id="lsp.goto_declaration"></a>
## `lsp.goto_declaration`()

Jumps to the declaration of the current symbol.

Returns: whether or not a declaration was found

<a id="lsp.goto_definition"></a>
## `lsp.goto_definition`()

Jumps to the definition of the current symbol.

Returns: whether or not a definition was found

<a id="lsp.goto_implementation"></a>
## `lsp.goto_implementation`()

Jumps to the implementation of the current symbol.

Returns: whether or not an implementation was found

<a id="lsp.goto_symbol"></a>
## `lsp.goto_symbol`([*symbol*])

Jumps to a symbol selected from a list based on project symbols that match a symbol.

Parameters:
- *symbol*:  String symbol to query for in the current project. If `nil`, symbols are
	presented from the current buffer.

<a id="lsp.goto_type_definition"></a>
## `lsp.goto_type_definition`()

Jumps to the definition of the current type.

Returns: whether or not a definition was found

<a id="lsp.hover"></a>
## `lsp.hover`([*position*=buffer.current_pos])

Shows a calltip with information about the identifier at a buffer position.

Parameters:
- *position*:  Position of the identifier to show information for.

<a id="lsp.log_rpc"></a>
## `lsp.log_rpc`

Log RPC correspondence to the LSP message buffer.

The default value is `false`.

<a id="lsp.select"></a>
## `lsp.select`()

Selects or expands the selection around the current position.

<a id="lsp.select_all_symbol"></a>
## `lsp.select_all_symbol`()

Selects all instances of the symbol at the current position as multiple selections.

<a id="lsp.server_commands"></a>
## `lsp.server_commands`

Map of lexer names to LSP language server commands or configurations, or functions that
return either a server command or a configuration.

Commands are simple string shell commands. Configurations are tables with the following keys:
- *command*: String shell command used to run the LSP language server.
- *init_options*: Table of initialization options to pass to the language server in the
	"initialize" request.

<a id="lsp.show_all_diagnostics"></a>
## `lsp.show_all_diagnostics`

Show all diagnostics if `show_diagnostics` is `true`.

The default value is `false`, and assumes any diagnostics on the current line or next line
are due to an incomplete statement during something like an autocompletion, signature help,
etc. request.

<a id="lsp.show_completions"></a>
## `lsp.show_completions`

Automatically show completions when a trigger character is typed (e.g.
'.').
The default value is `true`.

<a id="lsp.show_diagnostics"></a>
## `lsp.show_diagnostics`

Show diagnostics.

The default value is `true`, and shows them as annotations.

<a id="lsp.show_hover"></a>
## `lsp.show_hover`

Automatically show symbol information via mouse hovering.

The default value is `true`.

<a id="lsp.show_signature_help"></a>
## `lsp.show_signature_help`

Automatically show signature help when a trigger character is typed (e.g.
'(').
The default value is `true`.

<a id="lsp.signature_help"></a>
## `lsp.signature_help`([*no_cycle*=false])

Shows a calltip for the current function.

If a call tip is already shown, this will cycle to the next one if it exists.

Parameters:
- *no_cycle*:  Do not cycle to the next call tip. Setting this to `true` is
	useful when updating the current highlighted parameter.

<a id="lsp.snippet_completions"></a>
## `lsp.snippet_completions`

Allow completions to insert snippets instead of plain text, for language servers that
support it.

The default value is `true`.

<a id="lsp.start"></a>
## `lsp.start`([*cmd*])

Starts a language server based on the current language and project.

Parameters:
- *cmd*:  String language server command to run. The default value is read from
	`server_commands`.

<a id="lsp.stop"></a>
## `lsp.stop`()

Stops a running language server based on the current language.



