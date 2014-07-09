_ = require 'lodash'
fs = require 'fs'
path = require 'path'
async = require 'async2'
crypto = require 'crypto'
delay = (s, f) -> setTimeout f, s
did_apt_get_update_this_session = false

module.exports = -> _.assign @,
  # validation

  # use with resources that accept multiple values in the name argument
  getNames: (names) =>
    names = if Array.isArray names then names else names.compact().split ' '
    @die "One or more names are required." if names.length is 0
    return names

  # use with @execute() to validate the exit status code
  mustExit: (expected, cb) => (code) =>
    return cb code if code is expected
    @die "Expected exit code #{expected} but got #{code}."

  # use in situations where a simple test could avert two or more commands,
  # long-running commands, or potentially destructive commands.
  test: (cmd, [o]..., expected, cb) =>
    out = ''
    o =
      sudo: o?.sudo or false
      data: (data, steam) => out += data
    @execute cmd, o, (code) =>
      if expected.code?
        cb code is expected.code
      else if expected.rx?
        cb expected.rx.exec out

  # use in situations where failures are okay (compare @die()),
  # and to notify the user why you are skipping a command.
  skip: (reason, cb) =>
    @log "Skipping command(s) because #{reason}"
    cb()

  # used to asynchronously iterate an array in series
  each: (a, done_cb, each_cb, i=0) =>
    if a[i]?
      each_cb a[i], => @each a, done_cb, each_cb, i+1
    else
      done_cb()

  not_if: (cmd, do_cb, done_cb) =>
    @test cmd, code: 0, (res) =>
      unless res
        do_cb done_cb
      else
        done_cb()

  only_if: (cmd, do_cb, done_cb) =>
    @test cmd, code: 0, (res) =>
      if res
        do_cb done_cb
      else
        done_cb()


  # actual resources

  # use when you are sure the cmd does not need to be os agnostic,
  # or when you are sure you will only ever operate on one os
  execute: (cmd, [o]..., cb) =>
    @ssh.cmd "#{if o?.sudo then 'sudo ' else ''}#{cmd}", o, cb

  install: (pkgs, [o]..., cb) =>
    @test "dpkg -s #{@getNames(pkgs).join ' '} 2>&1 | grep 'is not installed and'", code: 0, (necessary) =>
      return @skip "package(s) already installed.", cb unless necessary
      ((next) =>
        # TODO: save .dotfile on remote host remembering last update date between sessions,
        #       and then check it and only run when its not there or has been >24hrs
        return next() if did_apt_get_update_this_session
        @execute 'apt-get update', sudo: true, @mustExit 0, ->
          did_apt_get_update_this_session = true
          next()
      )(=>
        @execute "DEBIAN_FRONTEND=noninteractive apt-get install -y "+
          "#{@getNames(pkgs).join ' '}", sudo: true, @mustExit 0, cb
      )

  uninstall: (pkgs, [o]..., cb) =>
    @test "dpkg -s #{@getNames(pkgs).join ' '} 2>&1 | grep 'install ok installed'", code: 0, (necessary) =>
      return @skip "package(s) already uninstalled.", cb unless necessary
      @execute "DEBIAN_FRONTEND=noninteractive apt-get "+
        "#{if o?.purge then 'purge' else 'uninstall'}"+
        " -y #{@getNames(pkgs).join ' '}", sudo: true, @mustExit 0, cb

  service: (pkgs, [o]..., cb) =>
    @each @getNames(pkgs), cb, (pkg, next) =>
      @execute "service "+
        "#{pkg}"+
        " #{o?.action or 'start'}", sudo: true, @mustExit 0, next

  chown: (paths, [o]..., cb) =>
    @die "user and/or group are required." unless o?.user or o?.group
    @each @getNames(paths), cb, (path, next) =>
      @execute "chown "+
        "#{if o?.recursive then '-R ' else ''}"+
        "#{o?.user}"+
        ".#{o?.group}"+
        " #{path}", o, @mustExit 0, next

  chmod: (paths, o, cb) =>
    @die "mode is required." unless o?.mode
    @each @getNames(paths), cb, (path, next) =>
      @execute "chmod "+
        "#{if o?.recursive then '-R ' else ''}"+
        "#{o?.mode}"+
        " #{path}", o, @mustExit 0, next

  directory: (paths, [o]..., cb) =>
    @each @getNames(paths), cb, (path, next) =>
      setModeAndOwner = =>
        @chown path, o, =>
          @chmod path, o, next
      @test "test -d #{path}", code: 1, (necessary) =>
        return @skip "directory already exists.", setModeAndOwner unless necessary
        @execute "mkdir"+
          "#{if o?.recursive then ' -p' else ''}"+
          " #{path}", sudo: true, setModeAndOwner

  # download a file from the internet to the remote host with wget
  download: (uris, [o]..., cb) =>
    @die "to is required." unless o?.to
    @each @getNames(uris), cb, (uri, nextFile) =>
      ((download)=>
        unless o?.replace # TODO: use checksum to assume replacement necessary
          @test "test -f #{uri}", code: 1, (necessary) =>
            download() if necessary
      )(=>
        @execute "wget --progress=dot #{uri}#{if o?.to then " -O #{o.to}" else ""}", o, =>
          return nextFile() unless o?.checksum
          @test "sha256sum #{o.to}", rx: /[a-f0-9]{64}/, (hash) =>
            @die "download failed; expected checksum #{JSON.stringify o.checksum} but found #{JSON.stringify hash[0]}." unless hash[0] is o.checksum
            nextFile()
      )

  # upload a file from localhost to the remote host with sftp
  upload: (paths, [o]..., cb) =>
    paths = path.join.apply null, paths if Array.isArray paths
    @die "to is required." unless o?.to
    # TODO: not if path with same sha256sum already exists
    @log "SFTP uploading #{fs.statSync(paths).size} bytes from #{JSON.stringify paths} to #{JSON.stringify o.to}..."
    @ssh.put paths, o.to, (err) =>
      @die "error during SFTP file transfer: #{err}" if err
      @log "SFTP upload complete."
      @chown o.to, o, =>
        @chmod o.to, o, =>
          @execute "mv #{o.to} #{o.final_to}", sudo: true, cb

  template: (paths, [o]..., cb) =>
    paths = path.join.apply null, paths
    @die "to is required." unless o?.to
    # use attrs from @server namespace
    sandbox = server: @server, networks: @networks
    if o?.local
      # locals will only apply if not provided anywhere else
      sandbox.server = _.merge o.local, @server
      o.local = null
    # render template from variables
    output = (require paths).apply sandbox
    tmp = crypto.createHash('sha1').update(output).digest('hex')
    @log "rendered template #{o.to} version #{tmp}"
    tmpFile = path.join __dirname, tmp
    o.final_to = o.to; o.to = '/tmp/'+tmp
    fs.writeFile tmpFile, output, (err) =>
      @die err if err
      @upload tmpFile, o, =>
        fs.unlink tmpFile, (err) =>
          @die err if err
          cb()

  reboot: ([o]..., cb) =>
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

  deploy_revision: (name, [o]..., cb) =>
    # TODO: support git
    # TODO: support shared dir, cached-copy, and symlinking logs and other stuff
    # TODO: support keep_releases
    releases_dir = path.join o.deploy_to, 'releases'
    @ssh.cmd "sudo mkdir -p #{releases_dir}", {}, =>
      out = ''
      @ssh.cmd "svn info --username #{o.svn_username} --password #{o.svn_password} --revision #{o.revision} #{o.svn_arguments} #{o.repository}", (data: (data, type) ->
        out += data.toString() if type isnt 'stderr'
      ), (code, signal) =>
        @die 'svn info failed' unless code is 0
        @die 'svn revision not found' unless current_revision = ((m = out.match /^Revision: (\d+)$/m) && m[1])
        release_dir = path.join releases_dir, current_revision
        @ssh.cmd "sudo mkdir -p #{release_dir}", {}, =>
          @ssh.cmd "sudo chown -R #{o.user}.#{o.group} #{release_dir}", {}, =>
            @ssh.cmd "sudo -u#{o.user} svn checkout --username #{o.svn_username} --password #{o.svn_password} #{o.repository} --revision #{current_revision} #{o.svn_arguments} #{release_dir}", {}, ->
              current_dir = path.join o.deploy_to, 'current'
              link release_dir, current_dir, cb

  link: (src, target, cb) =>
    @ssh.cmd "[ -h #{target} ] && sudo rm #{target}; sudo ln -s #{src} #{target}", {}, cb

  #cron: (name, [o]..., cb) ->
  #  cb()
