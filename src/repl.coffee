# A very simple Read-Eval-Print-Loop. Compiles one line at a time to JavaScript
# and evaluates it. Good for simple tests, or poking around the **Node.js** API.
# Using it looks like this:
#
#     coffee> console.log "#{num} bottles of beer" for num in [99..1]

# Start by opening up `stdin` and `stdout`.
stdin = process.openStdin()
stdout = process.stdout

# Require the **coffee-script** module to get access to the compiler.
CoffeeScript = require './coffee-script'
readline     = require 'readline'
{inspect}    = require 'util'
{Script}     = require 'vm'
Module       = require 'module'

# REPL Setup

# Config
REPL_PROMPT = 'coffee> '
REPL_PROMPT_MULTILINE = '------> '
REPL_PROMPT_CONTINUATION = '......> '
enableColours = no
unless process.platform is 'win32'
  enableColours = not process.env.NODE_DISABLE_COLORS

# Log an error.
error = (err) ->
  stdout.write (err.stack or err.toString()) + '\n'

## Autocompletion

# Regexes to match complete-able bits of text.
ACCESSOR  = /\s*([\w\.]+)(?:\.(\w*))$/
SIMPLEVAR = /(\w+)$/i

# Returns a list of completions, and the completed text.
autocomplete = (text) ->
  completeAttribute(text) or completeVariable(text) or [[], text]

# Attempt to autocomplete a chained dotted attribute: `one.two.three`.
completeAttribute = (text) ->
  if match = text.match ACCESSOR
    [all, obj, prefix] = match
    try obj = Script.runInThisContext obj
    catch e
      return
    return unless obj?
    obj = Object obj
    candidates = Object.getOwnPropertyNames obj
    while obj = Object.getPrototypeOf obj
      for key in Object.getOwnPropertyNames obj when key not in candidates
        candidates.push key
    completions = getCompletions prefix, candidates
    [completions, prefix]

# Attempt to autocomplete an in-scope free variable: `one`.
completeVariable = (text) ->
  free = text.match(SIMPLEVAR)?[1]
  free = "" if text is ""
  if free?
    vars = Script.runInThisContext 'Object.getOwnPropertyNames(Object(this))'
    keywords = (r for r in CoffeeScript.RESERVED when r[..1] isnt '__')
    candidates = vars
    for key in keywords when key not in candidates
      candidates.push key
    completions = getCompletions free, candidates
    [completions, free]

# Return elements of candidates for which `prefix` is a prefix.
getCompletions = (prefix, candidates) ->
  el for el in candidates when 0 is el.indexOf prefix

# Make sure that uncaught exceptions don't kill the REPL.
process.on 'uncaughtException', error


class REPLServer

  constructor: (options = {}) ->
    multilineMode = off
    # The current backlog of multi-line code.
    backlog = ''

    # Context property name to storage last value. '_' by default
    @lastValueKey = options.lastValueKey or '_'

    # Basic implementation of eval-ing a line/block of input
    # May be overridden
    @eval = options.eval or (code, context, filename, modulename, callback) ->
      try
        returnValue = CoffeeScript.eval "(#{code}\n)", {
          filename: filename
          modulename: modulename
          sandbox: context
        }
        callback null, returnValue
      catch err
        callback err

    @rli = rli = if stdin.readable and stdin.isRaw
      @createPipedInterface(stdin)
    else
      @createReadlineInterface()

    # Handle multi-line mode switch
    rli.input.on 'keypress', (char, key) ->
      # test for Ctrl-v
      return unless key and key.ctrl and not key.meta and not key.shift and key.name is 'v'
      cursorPos = rli.cursor
      rli.output.cursorTo 0
      rli.output.clearLine 1
      multilineMode = not multilineMode
      rli._line() if not multilineMode and backlog
      backlog = ''
      rli.setPrompt (newPrompt = if multilineMode then REPL_PROMPT_MULTILINE else REPL_PROMPT)
      rli.prompt()
      rli.output.cursorTo newPrompt.length + (rli.cursor = cursorPos)

    # Handle Ctrl-d press at end of last line in multiline mode
    rli.input.on 'keypress', (char, key) ->
      return unless multilineMode and rli.line
      # test for Ctrl-d
      return unless key and key.ctrl and not key.meta and not key.shift and key.name is 'd'
      multilineMode = off
      rli._line()

    rli.on 'attemptClose', =>
      if multilineMode
        multilineMode = off
        rli.output.cursorTo 0
        rli.output.clearLine 1
        rli._onLine rli.line
        return
      if backlog or rli.line
        backlog = ''
        rli.historyIndex = -1
        rli.setPrompt REPL_PROMPT
        rli.output.write '\n(^C again to quit)'
        rli._line (rli.line = '')
      else
        rli.close()

    rli.on 'close', ->
      rli.output.write '\n'
      rli.input.destroy()

    # The main REPL function. Called every time a line of code is entered.
    # Attempt to evaluate the command. If there's an exception, print it out instead
    # of exiting.
    rli.on 'line', (buffer) =>
      # remove single-line comments
      buffer = buffer.replace /(^|[\r\n]+)(\s*)##?(?:[^#\r\n][^\r\n]*|)($|[\r\n])/, "$1$2$3"
      # remove trailing newlines
      buffer = buffer.replace /[\r\n]+$/, ""
      if multilineMode
        backlog += "#{buffer}\n"
        rli.setPrompt REPL_PROMPT_CONTINUATION
        rli.prompt()
        return
      if !buffer.toString().trim() and !backlog
        rli.prompt()
        return
      code = backlog += buffer
      if code[code.length - 1] is '\\'
        backlog = "#{backlog[...-1]}\n"
        rli.setPrompt REPL_PROMPT_CONTINUATION
        rli.prompt()
        return
      rli.setPrompt REPL_PROMPT
      backlog = ''
      try
        @eval code, null, 'repl', 'repl', (err, returnValue) =>
          return error(err) if err?
          global[@lastValueKey] = returnValue unless returnValue is undefined
          rli.output.write "#{inspect returnValue, no, 2, enableColours}\n"
      rli.prompt()
    
  start: ->
    @rli.setPrompt REPL_PROMPT
    @rli.prompt()

  # handle piped input
  createPipedInterface: (stdin) ->
    pipedInput = ''
    piped =
      prompt: -> stdout.write @_prompt
      setPrompt: (p) -> @_prompt = p
      input: stdin
      output: stdout
      on: ->
    stdin.on 'data', (chunk) =>
      pipedInput += chunk
      return unless /\n/.test pipedInput
      lines = pipedInput.split "\n"
      pipedInput = lines[lines.length - 1]
      for line in lines[...-1] when line
        stdout.write "#{line}\n"
        @run line
      return
    stdin.on 'end', =>
      for line in pipedInput.trim().split "\n" when line
        stdout.write "#{line}\n"
        @run line
      stdout.write '\n'
      process.exit 0
    return piped

  # Create the REPL by listening to **stdin**.
  createReadlineInterface: ->
    if readline.createInterface.length < 3
      rli = readline.createInterface stdin, autocomplete
      stdin.on 'data', (buffer) -> rli.write buffer
    else
      rli = readline.createInterface stdin, stdout, autocomplete
    return rli

new REPLServer().start()