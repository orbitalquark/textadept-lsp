# Language Server Protocol

A client for Textadept that communicates over the [Language Server
Protocol][] (LSP) with language servers in order to provide autocompletion,
calltips, go to definition, and more. It implements version 3.12.0 of the
protocol, but does not support all protocol features. The [`Server.new()`](#Server.new)
function contains the client's current set of capabilities.

Install this module by copying it into your *~/.textadept/modules/* directory
or Textadept's *modules/* directory, and then putting the following in your
*~/.textadept/init.lua*:

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

When either Lua or cpp files are opened, their associated language servers
are automatically started (one per language, though).

Language Server features are available from the Tools > Language Server menu.
Note that not all language servers may support the menu options. You can
assign key bindings for these features, such as:

    keys['ctrl+alt+ '] = function() textadept.editing.autocomplete('lsp') end
    keys['ctrl+H'] = lsp.signature_help
    keys.f12 = lsp.goto_definition

**Note:** If you want to inspect the LSP messages sent back and forth, you
can use the Lua command entry to set `require('lsp').log_rpc = true`. It
doesn't matter if any LSPs are already active -- from this point forward all
messages will be logged to the "[LSP]" buffer.

**Warning:** Buggy language servers that do not respect the protocol may
cause this module and Textadept to hang, waiting for a response. There is no
recourse other than to force-quit Textadept and restart.

[Language Server Protocol]: https://microsoft.github.io/language-server-protocol/specification

## Fields defined by `lsp`

<a id="lsp.INDIC_ERROR"></a>
### `lsp.INDIC_ERROR` (number)

The error diagnostic indicator number.

<a id="lsp.INDIC_WARN"></a>
### `lsp.INDIC_WARN` (number)

The warning diagnostic indicator number.

<a id="events.LSP_INITIALIZED"></a>
### `events.LSP_INITIALIZED` (string)

Emitted when an LSP connection has been initialized.
  This is useful for sending server-specific notifications to the server upon
  init via [`Server:notify()`](#Server.notify).
  Emitted by [`lsp.start()`](#lsp.start).
  Arguments:

  * _`lang`_: The lexer name of the LSP language.
  * _`server`_: The LSP server.

<a id="events.LSP_NOTIFICATION"></a>
### `events.LSP_NOTIFICATION` (string)

Emitted when an LSP server emits an unhandled notification.
  This is useful for handling server-specific notifications. Responses can be
  sent via [`Server:respond()`](#Server.respond).
  An event handler should return `true`.
  Arguments:

  * _`lang`_: The lexer name of the LSP language.
  * _`server`_: The LSP server.
  * _`method`_: The string LSP notification method name.
  * _`params`_: The table of LSP notification params. Contents may be
    server-specific.

<a id="textadept.editing.autocompleters.lsp"></a>
### `textadept.editing.autocompleters.lsp` (function)

Autocompleter function for a language server.

<a id="lsp.log_rpc"></a>
### `lsp.log_rpc` (bool)

Log RPC correspondence to the LSP message buffer.
  The default value is `false`.

<a id="lsp.show_all_diagnostics"></a>
### `lsp.show_all_diagnostics` (bool)

Whether or not to show all diagnostics.
  The default value is `false`, and assumes any diagnostics on the current
  line or next line are due to an incomplete statement during something like
  an autocompletion, signature help, etc. request.


## Functions defined by `lsp`

<a id="Server.new"></a>
### `Server.new`(*lang, cmd, init\_options*)

Starts, initializes, and returns a new language server.

Parameters:

* *`lang`*: Lexer name of the language server.
* *`cmd`*: String command to start the language server.
* *`init_options`*: Optional table of options to be passed to the language
  server for initialization.

<a id="Server:handle_notification"></a>
### `Server:handle_notification`(*method, params*)

Handles an unsolicited notification from this language server.

Parameters:

* *`method`*: String method name of the notification.
* *`params`*: Table of parameters for the notification.

<a id="Server:handle_stdout"></a>
### `Server:handle_stdout`(*output*)

Processes unsolicited, incoming stdout from the Language Server, primarily to
look for notifications and act on them.

Parameters:

* *`output`*: String stdout from the Language Server.

<a id="Server:log"></a>
### `Server:log`(*message*)

Silently logs the given message.

Parameters:

* *`message`*: String message to log.

<a id="Server:notify"></a>
### `Server:notify`(*method, params*)

Sends a notification to this language server.

Parameters:

* *`method`*: String method name of the notification.
* *`params`*: Table of parameters for the notification.

<a id="Server:notify_opened"></a>
### `Server:notify_opened`(*buffer*)

Notifies this language server that the given buffer was opened.

Parameters:

* *`buffer`*: Buffer opened.

<a id="Server:read"></a>
### `Server:read`()

Reads and returns an incoming JSON message from this language server.

Return:

* table of data from JSON

<a id="Server:request"></a>
### `Server:request`(*method, params*)

Sends a request to this language server and returns the result of the
request.
Any intermediate notifications from the server are processed, but any
intermediate requests from the server are ignored.
Note: at this time, requests are synchronous, so the id number for a response
will be the same as the id number for a request.

Parameters:

* *`method`*: String method name of the request.
* *`params`*: Table of parameters for the request.

Return:

* table result of the request, or nil if the result was `json.null`.

<a id="Server:respond"></a>
### `Server:respond`(*id, result*)

Responds to an unsolicited request from this language server.

Parameters:

* *`id`*: Numeric ID of the request.
* *`result`*: Table result of the request.

<a id="Server:sync_buffer"></a>
### `Server:sync_buffer`()

Synchronizes the current buffer with this language server.
Changes are not synchronized in real-time, but whenever a request is about to
be sent.

<a id="lsp.find_references"></a>
### `lsp.find_references`()

Searches for project references to the current symbol and prints them.

<a id="lsp.goto_definition"></a>
### `lsp.goto_definition`()

Jumps to the definition of the current symbol, returning whether or not a
definition was found.

Return:

* `true` if a definition was found; `false` otherwise.

<a id="lsp.goto_implementation"></a>
### `lsp.goto_implementation`()

Jumps to the implementation of the current symbol, returning whether or not
an implementation was found.

Return:

* `true` if an implementation was found; `false` otherwise.

<a id="lsp.goto_symbol"></a>
### `lsp.goto_symbol`(*symbol*)

Jumps to a symbol selected from a list based on project symbols that match
the given symbol, or based on buffer symbols.

Parameters:

* *`symbol`*: Optional string symbol to query for in the current project. If
  `nil`, symbols are presented from the current buffer.

<a id="lsp.goto_type_definition"></a>
### `lsp.goto_type_definition`()

Jumps to the definition of the current type, returning whether or not a
definition was found.

Return:

* `true` if a definition was found; `false` otherwise.

<a id="lsp.hover"></a>
### `lsp.hover`(*position*)

Shows a calltip with information about the identifier at the given or current
position.

Parameters:

* *`position`*: Optional buffer position of the identifier to show
  information for. If `nil`, uses the current buffer position.

<a id="lsp.signature_help"></a>
### `lsp.signature_help`()

Shows a calltip for the current function.
If a call tip is already shown, cycles to the next one if it exists.

<a id="lsp.start"></a>
### `lsp.start`()

Starts a language server based on the current language.

<a id="lsp.stop"></a>
### `lsp.stop`()

Stops a running language server based on the current language.


## Tables defined by `lsp`

<a id="lsp.server_commands"></a>
### `lsp.server_commands`

Map of lexer names to LSP language server commands or configurations, or
functions that return either a server command or a configuration.
Commands are simple string shell commands. Configurations are tables with the
following keys:

  * `command`: String shell command used to run the LSP language server.
  * `init_options`: Table of initialization options to pass to the language
    server in the "initialize" request.

---
