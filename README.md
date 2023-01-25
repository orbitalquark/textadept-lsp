# Language Server Protocol

A client for Textadept that communicates over the [Language Server Protocol][] (LSP) with
language servers in order to provide autocompletion, calltips, go to definition, and more.
It implements version 3.17.0 of the protocol, but does not support all protocol features. The
[`Server.new()`](#Server.new) function contains the client's current set of capabilities.

Install this module by copying it into your *~/.textadept/modules/* directory or Textadept's
*modules/* directory, and then putting the following in your *~/.textadept/init.lua*:

    local lsp = require('lsp')

You can then set up some language server commands. For example:

    lsp.server_commands.lua = 'lua-lsp'
    lsp.server_commands.cpp = function()
      return 'cquery', {
        cacheDirectory = '/tmp/cquery-cache',
        compilationDatabaseDirectory = io.get_project_root(),
        progressReportFrequencyMs = -1
      }
    end

(For more example configurations, see the [wiki][].)

When either Lua or cpp files are opened, their associated language servers are automatically
started (one per language, though). Note that language servers typically require a root URI,
so this module uses `io.get_project_root()` for this. If the file being opened is not part
of a project recognized by Textadept, the language server will not be started.

Language Server features are available from the Tools > Language Server menu. Note that not
all language servers may support the menu options.

**Note:** If you want to inspect the LSP messages sent back and forth, you can use the Lua
command entry to set `require('lsp').log_rpc = true`. It doesn't matter if any LSPs are
already active -- from this point forward all messages will be logged to the "[LSP]" buffer.

**Warning:** Buggy language servers that do not respect the protocol may cause this module
and Textadept to hang, waiting for a response. There is no recourse other than to force-quit
Textadept and restart.

[Language Server Protocol]: https://microsoft.github.io/language-server-protocol/specification
[wiki]: https://github.com/orbitalquark/textadept/wiki/LSP-Configurations

## Lua Language Server

This module comes with a simple Lua language server that starts up when Textadept opens a
Lua file. The server looks in the project root for a *.lua-lsp* configuration file. That
file can have the following fields:

  - `ignore`: List of globs that match directories and files to ignore. Globs are relative
    to the project root. The default directories ignored are .bzr, .git, .hg, .svn, _FOSSIL_,
    and node_modules. Setting this field overrides the default.
  - `max_scan`: Maximum number of files to scan before giving up. This is not the number
    of Lua files scanned, but the number of files encountered in non-ignored directories.
    The primary purpose of this field is to avoid hammering the disk when accidentally
    opening a large project or root. The default value is 10,000.

For example:

  ignore = {'.git', 'build', 'test'}
  max_scan = 20000

## Key Bindings

Windows and Linux | macOS | Terminal | Command
-|-|-|-
**Tools**| | |
Ctrl+Space | ⌘Space<br/> ^Space | ^Space | Complete symbol
Ctrl+? | ⌘?<br/>^? | M-?<br/>Ctrl+?<sup>‡</sup> | Show documentation
F12 | F12 | F12 | Go To Definition

‡: Windows terminal version only.

## Fields defined by `lsp`

<a id="events.LSP_INITIALIZED"></a>
### `events.LSP_INITIALIZED` 

Emitted when an LSP connection has been initialized.
This is useful for sending server-specific notifications to the server upon init via
[`Server:notify()`](#Server.notify).
Emitted by [`lsp.start()`](#lsp.start).
Arguments:

  - *lang*: The lexer name of the LSP language.
  - *server*: The LSP server.

<a id="events.LSP_NOTIFICATION"></a>
### `events.LSP_NOTIFICATION` 

Emitted when an LSP server emits an unhandled notification.
This is useful for handling server-specific notifications.
An event handler should return `true`.
Arguments:

  - *lang*: The lexer name of the LSP language.
  - *server*: The LSP server.
  - *method*: The string LSP notification method name.
  - *params*: The table of LSP notification params. Contents may be server-specific.

<a id="events.LSP_REQUEST"></a>
### `events.LSP_REQUEST` 

Emitted when an LSP server emits an unhandled request.
This is useful for handling server-specific requests. Responses are sent using
[`Server:respond()`](#Server.respond).
An event handler should return `true`.
Arguments:

  - *lang*: The lexer name of the LSP language.
  - *server*: The LSP server.
  - *id*: The integer LSP request ID.
  - *method*: The string LSP request method name.
  - *params*: The table of LSP request params.

<a id="lsp.autocomplete_num_chars"></a>
### `lsp.autocomplete_num_chars` 

The number of characters typed after which autocomplete is automatically triggered.
The default value is `nil`, which disables this feature. A value greater than or equal to
3 is recommended to enable this feature.

<a id="lsp.log_rpc"></a>
### `lsp.log_rpc` 

Log RPC correspondence to the LSP message buffer.
The default value is `false`.

<a id="lsp.show_all_diagnostics"></a>
### `lsp.show_all_diagnostics` 

Whether or not to show all diagnostics if `show_diagnostics` is `true`.
The default value is `false`, and assumes any diagnostics on the current line or next line
are due to an incomplete statement during something like an autocompletion, signature help,
etc. request.

<a id="lsp.show_diagnostics"></a>
### `lsp.show_diagnostics` 

Whether or not to show diagnostics.
The default value is `true`, and shows them as annotations.


## Functions defined by `lsp`

<a id="Server.new"></a>
### `Server.new`(*lang*, *cmd*, *init_options*)

Starts, initializes, and returns a new language server.

Parameters:

- *lang*:  Lexer name of the language server.
- *cmd*:  String command to start the language server.
- *init_options*:  Optional table of options to be passed to the language server for
   initialization.

<a id="Server.handle_data"></a>
### `Server:handle_data`(*data*)

Helper function for processing a single message from the Language Server's notification stream.
Cache any incoming messages (particularly responses) that happen to be picked up.

Parameters:

- *data*:  String message from the Language Server.

<a id="Server.handle_notification"></a>
### `Server:handle_notification`(*method*, *params*)

Handles an unsolicited notification from this language server.

Parameters:

- *method*:  String method name of the notification.
- *params*:  Table of parameters for the notification.

<a id="Server.handle_request"></a>
### `Server:handle_request`(*id*, *method*, *params*)

Responds to a request from this language server.

Parameters:

- *id*:  ID number of the server's request.
- *method*:  String method name of the request.
- *params*:  Table of parameters for the request.

<a id="Server.handle_stdout"></a>
### `Server:handle_stdout`(*output*)

Processes unsolicited, incoming stdout from the Language Server, primarily to look for
notifications and act on them.

Parameters:

- *output*:  String stdout from the Language Server.

<a id="Server.log"></a>
### `Server:log`(*message*)

Silently logs the given message.

Parameters:

- *message*:  String message to log.

<a id="Server.notify"></a>
### `Server:notify`(*method*, *params*)

Sends a notification to this language server.

Parameters:

- *method*:  String method name of the notification.
- *params*:  Table of parameters for the notification.

<a id="Server.notify_opened"></a>
### `Server:notify_opened`()

Notifies this language server that the current buffer was opened, provided the language
server has not previously been notified.

<a id="Server.read"></a>
### `Server:read`()

Reads and returns an incoming JSON message from this language server.

Return:

- table of data from JSON

<a id="Server.request"></a>
### `Server:request`(*method*, *params*)

Sends a request to this language server and returns the result of the request.
Any intermediate notifications from the server are processed, but any intermediate requests
from the server are ignored.
Note: at this time, requests are synchronous, so the id number for a response will be the
same as the id number for a request.

Parameters:

- *method*:  String method name of the request.
- *params*:  Table of parameters for the request.

Return:

- table result of the request, or nil if the result was `json.null`.

<a id="Server.respond"></a>
### `Server:respond`(*id*, *result*)

Responds to an unsolicited request from this language server.

Parameters:

- *id*:  Numeric ID of the request.
- *result*:  Table result of the request.

<a id="Server.sync_buffer"></a>
### `Server:sync_buffer`()

Synchronizes the current buffer with this language server.
Changes are not synchronized in real-time, but whenever a request is about to be sent.

<a id="_G.textadept.editing.autocompleters.lsp"></a>
### `_G.textadept.editing.autocompleters.lsp`()

Autocompleter function for a language server.

<a id="lsp.autocomplete"></a>
### `lsp.autocomplete`()

Requests autocompletion at the current position, returning `true` on success.

<a id="lsp.find_references"></a>
### `lsp.find_references`()

Searches for project references to the current symbol and prints them like "Find in Files".

<a id="lsp.goto_declaration"></a>
### `lsp.goto_declaration`()

Jumps to the declaration of the current symbol, returning whether or not a declaration was found.

Return:

- `true` if a declaration was found; `false` otherwise.

<a id="lsp.goto_definition"></a>
### `lsp.goto_definition`()

Jumps to the definition of the current symbol, returning whether or not a definition was found.

Return:

- `true` if a definition was found; `false` otherwise.

<a id="lsp.goto_implementation"></a>
### `lsp.goto_implementation`()

Jumps to the implementation of the current symbol, returning whether or not an implementation
was found.

Return:

- `true` if an implementation was found; `false` otherwise.

<a id="lsp.goto_symbol"></a>
### `lsp.goto_symbol`(*symbol*)

Jumps to a symbol selected from a list based on project symbols that match the given symbol,
or based on buffer symbols.

Parameters:

- *symbol*:  Optional string symbol to query for in the current project. If `nil`, symbols
   are presented from the current buffer.

<a id="lsp.goto_type_definition"></a>
### `lsp.goto_type_definition`()

Jumps to the definition of the current type, returning whether or not a definition was found.

Return:

- `true` if a definition was found; `false` otherwise.

<a id="lsp.hover"></a>
### `lsp.hover`(*position*)

Shows a calltip with information about the identifier at the given or current position.

Parameters:

- *position*:  Optional buffer position of the identifier to show information for. If `nil`,
   uses the current buffer position.

<a id="lsp.select"></a>
### `lsp.select`()

Selects or expands the selection around the current position.

<a id="lsp.select_all_symbol"></a>
### `lsp.select_all_symbol`()

Selects all instances of the symbol at the current position as multiple selections.

<a id="lsp.signature_help"></a>
### `lsp.signature_help`()

Shows a calltip for the current function.
If a call tip is already shown, cycles to the next one if it exists.

<a id="lsp.start"></a>
### `lsp.start`(*cmd*)

Starts a language server based on the current language.

Parameters:

- *cmd*:  Optional language server command to run. The default is read from `server_commands`.

<a id="lsp.stop"></a>
### `lsp.stop`()

Stops a running language server based on the current language.


## Tables defined by `lsp`

<a id="lsp.server_commands"></a>
### `lsp.server_commands`

Map of lexer names to LSP language server commands or configurations, or functions that
return either a server command or a configuration.
Commands are simple string shell commands. Configurations are tables with the following keys:

  - *command*: String shell command used to run the LSP language server.
  - *init_options*: Table of initialization options to pass to the language server in the
    "initialize" request.

---
