_ = require 'lodash'
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
        cb rx.exec out

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

  # actual resources

  # use when you are sure the cmd does not need to be os agnostic,
  # or when you are sure you will only ever operate on one os
  execute: (cmd, [o]..., cb) =>
    @ssh.cmd "#{if o?.sudo then 'sudo ' else ''}#{cmd}", cb

  install: (pkgs, [o]..., cb) =>
    @test "dpkg -s #{@getNames(pkgs).join ' '} | grep 'is not installed and'", code: 0, (necessary) =>
      return @skip "package(s) already installed.", cb unless necessary
      ((next) =>
        # TODO: save .dotfile on remote host remembering last update date between sessions,
        #       and then check it and only run when its not there or has been >24hrs
        return next() if did_apt_get_update_this_session
        @execute 'apt-get update', sudo: true, @mustExit 0, ->
          did_apt_get_update_this_session = true
          next()
      )(=>
        @execute "apt-get install -y "+
          "#{@getNames(pkgs).join ' '}", sudo: true, @mustExit 0, cb
      )

  uninstall: (pkgs, [o]..., cb) =>
    @test "dpkg -s #{@getNames(pkgs).join ' '} 2>&1 | grep 'install ok installed'", code: 0, (necessary) =>
      return @skip "package(s) already uninstalled.", cb unless necessary
      @execute "apt-get "+
        "#{if o?.purge then 'purge' else 'uninstall'}"+
        " #{@getNames(pkgs).join ' '}", sudo: true, @mustExit 0, cb

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
  wget_download: (localfile, [o]..., cb) ->
    throw "source is required" unless o?.source
    go = -> execute "wget #{o.source} -O #{localfile}", ->
      if o.checksum
        buf = ''
        ssh.cmd "sha256sum #{localfile} | cut -d' ' -f1", data: ((data, extended) ->
          return if extended is 'stderr'
          buf += data.toString()
        ), ->
          buf = buf.trim()
          unless buf.trim() is o.checksum
            throw "download failed; checksum mismatch. expected #{JSON.stringify o.checksum} but got #{JSON.stringify buf} instead."
          cb()
    return go() unless o.not_if
    execute o.not_if, (code) ->
      return cb() if code is 0
      go()

  # upload a file from localhost to the remote host with sftp
  sftp_upload: (file, [o]..., cb) ->
    # TODO: not if file with same sha256sum already exists in o.path
    throw "path is required" unless o?.path
    go = ->
      path = require 'path'
      src = path.join(process.cwd(), 'scripts', 'zing', 'files', file)
      dst = o.path
      fs = require 'fs'
      Logger.out type: 'info', "beginning SFTP #{fs.statSync(src).size} byte file transfer from #{JSON.stringify src} to #{JSON.stringify dst}..."
      ssh.put path.join(process.cwd(), 'scripts', 'zing', 'files', file), o.path, (err) ->
        throw "error during file transfer: #{err}" if err
        Logger.out type: 'info', "file transferred successfully."
        chown o, ->
          chmod o, cb
    return go() unless o.only_if
    execute o.only_if, (code) ->
      return cb() if code isnt 0
      go()

  reboot: ([o]..., cb) =>
    @log '''
           (╯°□°）╯ ︵ ┻━┻
    ###############################
    ###############################
    #####  REBOOTING SERVER #######
    ###############################
    ###############################
    '''
    @execute "reboot", sudo: true, =>
      @log "waiting for server to reboot...", =>
        delay o?.wait or 60*1000, =>
          @log "re-establishing ssh connection", =>
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

  #put_file: (src, [o]..., cb) =>
  #  tmp_file = path.join '/', 'tmp', crypto.createHash('sha1').update(''+ (new Date()) + Math.random()).digest('hex')
  #  @log "sftp local file #{src} to #{tmp_file}"
  #  @ssh.put src, tmp_file, (err) =>
  #    return cb err if err
  #    @ssh.cmd "sudo chown #{o.user or 'root'}.#{o.user or 'root'} #{tmp_file}", {}, =>
  #      @ssh.cmd "sudo mv #{tmp_file} #{o.target}", {}, cb

  #put_template: (src, [o]..., cb) =>
  #  # TODO: find out how to put a string via sftp
  #  @put_file.apply @, arguments

  #cron: (name, [o]..., cb) ->
  #  cb()
