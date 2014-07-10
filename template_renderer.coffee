CoffeeScript = require 'coffee-script'
vm = require 'vm'

module.exports =
  render: (template, variables) ->
    indent = '  '
    level = 0
    indentation = -> o=''; o += indent for i in [0...level]; o
    newline = "\n"
    x = 0
    out = "out = ''#{newline}"
    lastToken = {}
    plain = (t) ->
      if lastToken.flow
        t = t.replace `/(\r?\n)/`, '' # strip one newline
      out += "#{indentation()}out += #{JSON.stringify t}#{newline}"
    variable = (v) -> out += "#{indentation()}out += #{v}#{newline}"
    template.replace `/<%(=?) *(.+?) *(:?) *%>/g`, ->
      token =
        returnable: arguments[1] is '='
        words: if arguments[2] is 'end' then '' else arguments[2]
        indent: switch true
          when arguments[3] is ':' then 1
          when arguments[2] is 'end' then -1
          else 0
        x: arguments[4]
        len: arguments[0].length
      if token.x > x
        plain template.substr x, token.x - x
      if token.indent isnt 0
        token.flow = true
      if token.words.match `/^else */i`
        token.flow = true
        level--
      if token.returnable
        variable token.words
      else
        out += "#{indentation()}#{token.words}#{newline}"
      level += token.indent
      x = token.x + token.len
      lastToken = token
      return
    if x < template.length
      plain template.substr x, template.length - x
    #console.log out
    js = CoffeeScript.compile out, bare: true
    js = "(function(){#{js.substr 7}}).apply(root);"
    #console.log js
    sandbox = root: variables, out: ''
    vm.runInNewContext js, sandbox, 'a.vm'
    return sandbox.out
