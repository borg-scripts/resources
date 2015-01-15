_ = require 'lodash'
fs = require 'fs'
path = require 'path'
async = require 'async2'
crypto = require 'crypto'
TemplateRenderer = require './template_renderer'
delay = (s, f) -> setTimeout f, s
bash_esc = (s) -> (''+s).replace `/([^0-9a-z-])/gi`, '\\$1'
bash_prefix = (pre, val) -> if val then " #{pre}#{val}" else ''

module.exports = -> _.assign @,
  # use with resources that accept multiple values in the name argument
  getNames: (names) =>
    names = if Array.isArray names then names else names.compact().split ' '
    @die "One or more names are required." if names.length is 0
    return names

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

  # use when you are sure the cmd does not need to be os agnostic,
  # or when you are sure you will only ever operate on one os
  execute: (cmd, [o]...) => (cb) =>
    o ||= {}
    sudo = ''
    if o.sudo
      if typeof o.sudo is 'boolean' and o.sudo is true
        sudo = 'sudo '
      else if typeof o.sudo is 'string'
        sudo = 'sudo '
        sudo += "-u#{o.sudo} " if o.sudo isnt 'root'
      cmd = "#{if o.cwd then "cd #{o.cwd} && " else ""}#{sudo}#{cmd}"
    else if o.su
      cmd = if o.cwd then "cd #{o.cwd} && #{cmd}" else cmd
      cmd = "sudo su - #{if typeof o.su is 'string' and o.su isnt 'root' then o.su+' ' else ''}-c #{bash_esc cmd}"

    tries_remaining = o.retry
    try_again = null; try_again = =>
      error = null; out = ''; o.data ||= (data) => out += data
      @ssh.cmd cmd, o, (code) =>
        # use test in situations where a single test command could avoid
        # additional, long-running, or potentially destructive commands;
        # for when you want to do your own custom logic to handle and react
        # to the result of the execution.
        if typeof o.test is 'function'
          @inject_flow(=> o.test code: code, out: out)(cb)
          return

        o.expect ||= 0 unless o.ignore_errors
        if 'expect' of o
          error = switch typeof o.expect
            when 'object' then if null is out.match o.expect # rx match output
              "Expected regex #{o.expect} to match output, but it doesn't."
            when 'number' then if code isnt o.expect # int match exit code
              "Expected exit code #{o.expect}, but got #{code}."
            when 'string' then if -1 is out.indexOf o.expect # case-sensitive string match output
              "Expected string #{JSON.stringify o.expect} to match case-sensitive output, but it doesn't."
            else
              "Unexpected typeof expect passed to @execute(). Cannot continue."

        if code isnt 0
          if not error
            @log("NOTICE: Non-zero exit code #{o.expect} was expected. Will continue.") =>
          else if o.ignore_errors
            @log("NOTICE: Non-zero exit code #{o.expect} can be ignored. Will continue.") =>

        if error
          if o.retry
            if --tries_remaining > 0
              @log(type: 'err', "#{error} Will try again...") =>
                try_again()
            else
              @die "#{error} Tried #{o.retry} times. Giving up."
          else
            @die error
        else
          cb (if o.ignore_errors then null else error), code: code, out: out
    try_again()

  # appends line only if no matching line is found
  append_line_to_file: (file, [o]...) => @inject_flow =>
    @die "@file_append_line() unless_find and append are required." unless o?.unless_find and o?.append
    @then @execute "grep #{bash_esc o.unless_find} #{bash_esc file}", _.merge o, test: ({code}) =>
      if code is 0
        @then @log "Matching line found, not appending"
      else
        @then @log "Matching line not found, appending..."
        @then @execute "echo #{bash_esc o.append} | sudo tee -a #{bash_esc file}", _.merge o, test: ({code}) =>
          @die "FATAL ERROR: unable to append line." unless code is 0

  # replaces line only when/where matching line is found
  replace_line_in_file: (file, [o]...) => (cb) =>
    @die "@file_replace_line() when_find and replace are required." unless o?.if_find and o?.replace
    @then @execute "grep #{bash_esc o.if_find} #{bash_esc file}", _.merge o, test: ({code}) =>
      if code is 0
        @then @log "Matching line found, replacing..."
        @then @execute "sed -i #{bash_esc "s/#{o.if_find}.*/#{bash_esc o.replace}/"} #{bash_esc file}", _.merge o, test: ({code}) =>
          @die "FATAL ERROR: unable to replace line." unless code is 0
      else
        @then @log "Matching line not found, not replacing"

  package_update: => @inject_flow =>
    # TODO: save .dotfile on remote host remembering last update date between sessions,
    #       and then check it and only run when its not there or has been >24hrs
    @then @execute 'apt-get update', sudo: true, retry: 3, expect: 0
    # also update packages to latest releases
    @then @execute 'DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y', sudo: true, retry: 3, expect: 0

  install: (pkgs, [o]...) => @inject_flow =>
    @then @execute "dpkg -s #{@getNames(pkgs).join ' '} 2>&1 | grep 'is not installed and'", test: ({code}) =>
      return @then @log "Skipping package(s) already installed." if code isnt 0
      @then @execute "DEBIAN_FRONTEND=noninteractive apt-get install -y "+
        "#{@getNames(pkgs).join ' '}", sudo: true, retry: 3, expect: 0

  uninstall: (pkgs, [o]...) => @inject_flow =>
    @then @execute "dpkg -s #{@getNames(pkgs).join ' '} 2>&1 | grep 'install ok installed'", test: ({code}) =>
      return @then @log "Skipping package(s) already uninstalled." if code isnt 0
      @then @execute "DEBIAN_FRONTEND=noninteractive apt-get "+
        "#{if o?.purge then 'purge' else 'uninstall'}"+
        " -y #{@getNames(pkgs).join ' '}", sudo: true, expect: 0

  service: (pkgs, [o]...) => (cb) =>
    for pkg in @getNames(pkgs)
      @then @execute "service "+
        "#{pkg}"+
        " #{o?.action or 'start'}", sudo: true, expect: 0

  chown: (paths, [o]...) => @inject_flow =>
    @die "@chown() owner and/or group are required." unless o?.owner or o?.group
    for _path in @getNames(paths)
      @then @execute "chown "+
        "#{if o?.recursive then '-R ' else ''}"+
        "#{o?.owner}"+
        ".#{o?.group}"+
        " #{_path}", o, expect: 0

  chmod: (paths, o) => @inject_flow =>
    @die "mode is required." unless o?.mode
    for _path in @getNames(paths)
      @then @execute "chmod "+
        "#{if o?.recursive then '-R ' else ''}"+
        "#{o?.mode}"+
        " #{_path}", o, expect: 0

  directory: (paths, [o]...) => @inject_flow =>
    o ||= {}; o.mode ||= '0755'
    recursive = o.recursive
    for _path in @getNames(paths)
      do (_path) =>
        @then @execute "test -d #{_path}", test: ({code}) =>
          if code is 0
            @then @log 'Skipping existing directory.'
          else
            @then @execute "mkdir #{if recursive then ' -p' else ''} #{_path}", o
          delete o.recursive # creating directories recursively != chown/chmod recursively
          @then @chown [_path], o
          @then @chmod [_path], o

  template: (paths, [o]...) => @inject_flow =>
    if o?.hasOwnProperty 'content'
      # template from string
      o.to = paths
      template = o.content
      template = @decrypt o.content if o?.decrypt
    else
      # template from disk
      paths = path.join.apply null, @getNames paths
      template = fs.readFileSync "#{paths}.coffee", encoding: if o?.decrypt then 'binary' else 'utf-8'
      template = @decrypt template if o?.decrypt

    @die "to is required." unless o?.to

    # compile template variables
    # from @server attributes
    variables = server: @server, networks: @networks

    # and provided variables key
    if o?.variables
      variables = _.merge o.variables, variables
      o.variables = null # prevent template from accidentally modifying provided object

    # render template from variables
    output = TemplateRenderer.render.apply variables, [template]
    @then @string_to_file output, o

   string_to_file: (str, [o]...) => @inject_flow =>
      ver = crypto.createHash('sha1').update(str).digest('hex')+Math.random().toString(36).substring(2,8)
      @then @log "rendering file #{o.to} version #{ver}"
      @then -> console.log "---- BEGIN FILE ----\n#{str}\n--- END FILE ---"
      # write string to file on local disk
      # NOTICE: for windows compatibility this could go into __dirname locally
      tmpFile = path.join '/tmp/', 'local-'+ver
      o.final_to = o.to; o.to = '/tmp/remote-'+ver
      @then @call fs.writeFile, tmpFile, str
      # upload file
      @then @upload tmpFile, o
      # delete file
      @then @call fs.unlink, tmpFile, err: ->

  remote_file_exists: (file, [o]...) => @inject_flow =>
    @die "@remote_file_exists true: or false: callback function is required." unless o?.true or o?.false
    unless o.compare_checksum
      @then @execute "stat #{file}", sudo: o.sudo, test: ({code}) =>
        if code is 0
          @then @log "Remote file #{file} exists."
          o.true?()
        else
          o.false?()
    else
      local_checksum = ''
      @then (cb) => fs.readFile o.compare_checksum, (err, data) =>
        @die err if err
        local_checksum = @checksum data, 'sha256'
        cb()
      @then @execute "sha256sum #{file}", test: ({out}) =>
        if null isnt matches = out.match /[a-f0-9]{64}/
          if matches[0] is local_checksum
            @then @log "Remote file checksum #{matches[0]} matches local checksum #{local_checksum}."
            o.true?()
          else
            @then @log "Remote file checksum #{matches[0]} does not match local checksum #{local_checksum}."
            o.false?()
        else
          @then @log "Unexpected problem reading remote file checksum. Assuming remote file checksum does not match local checksum #{local_checksum}."
          o.false?()

  # upload a file from localhost to the remote host with sftp
  upload: (paths, [o]...) => @inject_flow (end) =>
    if Array.isArray paths
      _path = path.join.apply null, paths
    else
      _path = paths
    @die "to is required." unless o?.to
    if o.decrypt
      local_tmp = "/tmp/#{Math.random().toString(36).substring(2,8)}"
      # decrypt file to temporary location on local disk for easy upload
      @then @log "Decrypting file #{_path}..."
      @then (cb) => fs.writeFileSync local_tmp, @decrypt fs.readFileSync _path; cb()
    else
      local_tmp = _path
    unless o.final_to
      final_to = o.to
      to = "/tmp/#{Math.random().toString(36).substring(2,8)}"
    else
      final_to = o.final_to
      to = o.to

    @then (cb) =>
      @log("SFTP uploading #{fs.statSync(local_tmp).size} #{if o.decrypt then 'decrypted ' else ''}bytes from #{JSON.stringify _path} to #{JSON.stringify final_to}#{if final_to isnt o.to then " through temporary file #{JSON.stringify to}" }...")(cb)

    @then @remote_file_exists to, true: =>
      @then @execute "rm -f #{to}", sudo: o.sudo

    @then @remote_file_exists final_to, true: =>
      @then @remote_file_exists final_to, compare_checksum: local_tmp
        , true: =>
          @then @log "Upload would be pointless since checksums match; skipping to save time."
          end()
        , false: =>
          @then @execute "rm -f #{final_to}", sudo: o.sudo

    @then @call @ssh.put, local_tmp, to, err: (err) =>
      @die "error during SFTP file transfer: #{err}" if err

    if o.decrypt
      # delete temporarily decrypted version of the file from local disk
      @then @call fs.unlink, local_tmp, err: ->

    # set ownership and permissions
    @then @chown to, o
    @then @chmod to, o

    # move into final location
    @then @execute "mv #{to} #{final_to}", sudo: o.sudo

    @then @log "SFTP upload complete."

  # download a file from the internet to the remote host with wget
  download: (uris, [o]...) => @inject_flow =>
    @die "to is required." unless o?.to
    for uri in @getNames uris
      do (uri) =>
        @then @execute "wget -nv"+
          " #{uri}"+
          (if o.replace then '-nc ' else '')+
          (bash_prefix '-P ', o.path)+
          (bash_prefix '-O ', o.to), o
        @then @chown o.to, o
        @then @chmod o.to, o
        return unless o?.checksum
        @then @execute "sha256sum #{o.path or ''}#{o.to}", test: ({out}) =>
          if null is matches = out.match /[a-f0-9]{64}/ or matches[0] isnt o.checksum
            @die "download failed; expected checksum #{JSON.stringify o.checksum} but found #{JSON.stringify matches[0]}."

  reboot: ([o]...) => (cb) =>
    o ||= {}; o.wait ||= 60*1000
    @log '''
    ###############################
    #####  REBOOTING SERVER #######       (╯°o°)╯ ︵ ┻━┻
    ###############################
    '''
    @execute "reboot", sudo: true, =>
      @log "waiting #{o.wait}ms for server to reboot...", =>
        delay o.wait, =>
          @log "attempting to re-establish ssh connection", =>
            @ssh.connect =>
              cb()

  user: (name, [o]...) => (cb) =>
    @test "id #{name}", code: 0, (exists) =>
      return @skip "user #{name} exists.", cb if exists
      cmd = "useradd #{name} \\\n"+
        "  --create-home \\\n"+
        "  --user-group \\\n"+
        (if o?.comment then "  --comment #{bash_esc o.comment} \\\n" else "")+
        (if o?.password then "  --password #{bash_esc o.password} \\\n" else "")+
        "  --shell #{o.shell or "/bin/bash"} \\\n"+
        "  ;"
      @execute cmd, sudo: o?.sudo, =>
        a = (next) =>
          return next() unless o?.group_name
          @execute "usermod -g #{o.group_name} #{name}", sudo: o?.sudo, next
        b = (next) =>
          return next() unless o?.groups?.length > 0
          @each o.groups, next, (group, next) =>
            @execute "usermod -a -G #{group} #{name}", sudo: o?.sudo, next
        c = (next) =>
          return next() unless o?.ssh_keys?.length > 0
          @each o.ssh_keys, cb, (key, next) =>
            @execute "mkdir -pm700 $(echo ~#{name})/.ssh/", sudo: o?.sudo, =>
              @execute "touch $(echo ~#{name})/.ssh/authorized_keys", sudo: o?.sudo, =>
                @execute "chmod 600 $(echo ~#{name})/.ssh/authorized_keys", sudo: o?.sudo, =>
                  @execute "echo #{bash_esc key} | sudo tee -a $(echo ~#{name})/.ssh/authorized_keys >/dev/null", =>
                    @execute "chown -R #{name}.#{name} $(echo ~#{name})/.ssh", sudo: o?.sudo, next
        a( (-> b(-> c(-> cb() ) ) ) ) # execute in series; hide repetition; hide pyramid

  group: (name, [o]...) => @inject_flow =>
    @then @execute "groupadd #{name}", _.merge ignore_errors: true, o

  link: (src, [o]...) => (cb) =>
    @die "target is required." unless o?.target
    @test "test -L #{o.target}", code: 1, (necessary) =>
      if necessary
        @execute "ln -s #{src} #{o.target}", o, expect: 0, cb
      else
        @execute "rm #{o.target}", o, =>
          @execute "ln -s #{src} #{o.target}", o, expect: 0, cb

  deploy: (name, [o]...) => (cb) =>
    # TODO: support shared dir, cached-copy, and symlinking logs and other stuff
    # TODO: support keep_releases
    o.sudo = o.owner
    o.keep_releases ||= 3
    privateKeyPath = "$(echo ~#{o.owner})/.ssh/id_rsa" # TODO: make this a safer name; to avoid overwriting existing file
    @directory ["$(echo ~#{o.owner})/"], owner: o.owner, group: o.group, sudo: true, recursive: true, mode: '0700', =>
      @directory ["$(echo ~#{o.owner})/.ssh/"], owner: o.owner, group: o.group, sudo: true, recursive: true, mode: '0700', =>
        # write ssh key to ~/.ssh/
        @string_to_file o.git.deployKey, owner: o.owner, group: o.group, sudo: true, to: privateKeyPath, mode: '0600', =>
          # create the release dir
          @execute 'echo -e "Host github.com\\n\\tStrictHostKeyChecking no\\n" | '+"sudo -u #{o.sudo} tee -a $(echo ~#{o.owner})/.ssh/config", => # TODO: find a better alternative
            @test "git ls-remote #{o.git.repo} #{o.git.branch}", o, rx: `/[a-f0-9]{40}/`, (matches) =>
              @die "github repo didn't have the branch we're expecting #{o.git.branch}" unless Array.isArray matches
              remoteRef = matches[0]
              @directory o.deploy_to, owner: o.owner, group: o.group, sudo: true, recursive: true, =>
                release_dir = "#{o.deploy_to}/releases/#{remoteRef}"
                @directory release_dir, owner: o.owner, group: o.group, sudo: true, recursive: true, =>
                  @execute "git clone -b #{o.git.branch} #{o.git.repo} #{release_dir}", sudo: o.sudo, =>
                    @link release_dir, target: "#{o.deploy_to}/current", sudo: o.sudo, cb
