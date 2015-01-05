CoffeeScript = require 'coffee-script'

module.exports =
  # use render.apply(variables) to pass data to template
  render: (template) ->
    indent = '  '
    level = 0
    indentation = -> o=''; o += indent for i in [0...level]; o
    newline = "\n"
    x = 0
    out = "out = ''#{newline}"
    lastToken = null
    plain = (t) ->
      unless lastToken is null or lastToken.returnable
        t = t.replace `/(\r?\n)/`, '' # strip one newline
      out += "#{indentation()}out += #{JSON.stringify t}#{newline}"
    variable = (v) -> out += "#{indentation()}out += #{v}#{newline}"
    template = template.replace '#{', '\#{' # disallow usual coffee string interpolation because ruby templates use it, too
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
        t = template.substr x, token.x - x
        unless token.returnable
          t = t.replace `/[ \t]+$/`, '' # strip end line space
        plain t
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
    # TODO: wrap in try...catch, parse linenum from backtrace, echo coffee at linenum +/- 5 lines with printed line num and arrow on problem line
    js = CoffeeScript.compile out, bare: true
    final_out = ''
    js = "#{js}\nfinal_out = out;"
    eval(js) or console.log js
    return final_out
