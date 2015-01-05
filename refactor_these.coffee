  # validation


  # use with @execute() to validate the exit status code
  mustExit: (expected, cb) => (code) =>
    return cb code if code is expected
    @die "Expected exit code #{expected} but got #{code}."

  # use in situations where failures are okay (compare @die()),
  # and to notify the user why you are skipping a command.
  skip: (reason) => (cb) =>
    @log "Skipping command(s) because #{reason}"
    cb()

  # used to asynchronously iterate an array or an object in series
  each: (o, done_cb, each_cb, i=0) =>
    if Array.isArray o
      if o[i]?
        each_cb o[i], => @each o, done_cb, each_cb, i+1
      else
        done_cb()
    else if typeof o is 'object'
      tuples = []
      for own k of o
        tuples.push [k, o[k]]
      @each tuples, done_cb, each_cb
    else # empty
      done_cb() # carry on

  not_if: (cmd, do_cb) => (done_cb) =>
    @test cmd, code: 0, (res) =>
      unless res
        do_cb done_cb
      else
        done_cb()

  only_if: (cmd, do_cb) => (done_cb) =>
    @test cmd, code: 0, (res) =>
      if res
        do_cb done_cb
      else
        done_cb()

  unless: (cmd, do_cb) =>
    @then (cb) =>
      @not_if cmd, (=>
        old_Q = @_Q; @_Q = []
        do_cb()
        @finally =>
          @_Q = old_Q
          cb()
      ), cbtest_v2: (cmd, [o]..., test_cb, success_cb, fail_cb) =>
    @execute cmd, o, (code) =>
      #cb if test_cb.apply code: code then null else die_msg
      if test_cb.apply(code: code)
        success_cb()
      else
        fail_cb()


  # need a better name for this.
  # kind of want to make it part of @execute with some option passed or refactor to make it the norm
  get_remote_str: (cmd, cb) => out = ''; @execute cmd, ( data: (str) => out += str ), (code) => cb code, out.trim()










  setEnv: (k, [o]...) => (cb) =>
    @die "value is required." unless o?.value?
    # remove any lines referring to the same key; this prevents duplicates
    file = "/etc/environment"
    @execute "sed -i '/^#{k}=/d' #{file}", sudo: true, =>
      # append key and value
      @execute "echo '#{k}=#{o.value}' | sudo tee -a #{file} >/dev/null", @mustExit 0, cb #=>
        ## set in current env
        #@execute "export #{k}=\"#{o.value}\"", cb

  addPackageSource: (k, [o]...) => (cb) =>
    @die "Mirror is required." unless o?.mirror?
    @die "Channel is required." unless o?.channel?
    @die "Repository name is required." unless o?.repo?

    @test_v2 "stat /usr/bin/apt", (-> @code is 0)
    , =>
      @execute "echo \"deb #{o.mirror} #{o.channel} #{o.repo}\" | sudo tee -a /etc/apt/sources.list", sudo: true, cb
    , =>
      @skip "we don't know how to add a package source on non-Debian systems", cb
