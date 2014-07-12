_ = require 'lodash'
fs = require 'fs'
path = require 'path'
async = require 'async2'
crypto = require 'crypto'
TemplateRenderer = require './template_renderer'
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

  unless: (cmd, do_cb) =>
    @then (cb) =>
      @not_if cmd, (=>
        old_Q = @_Q; @_Q = []
        do_cb()
        @finally =>
          @_Q = old_Q
          cb()
      ), cb

  # actual resources

  # use when you are sure the cmd does not need to be os agnostic,
  # or when you are sure you will only ever operate on one os
  execute: (cmd, [o]..., cb) =>
    sudo = ''
    if o?.sudo
      if typeof o.sudo is 'boolean' and o.sudo is true
        sudo = 'sudo '
      else if typeof o.sudo is 'string'
        sudo = "sudo -u#{o.sudo} "
    @ssh.cmd "#{sudo}#{cmd}", o, cb

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
    @die "owner and/or group are required." unless o?.owner or o?.group
    @each @getNames(paths), cb, (path, next) =>
      @execute "chown "+
        "#{if o?.recursive then '-R ' else ''}"+
        "#{o?.owner}"+
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
    o.mode ||= '0755'
    @each @getNames(paths), cb, (path, next) =>
      setModeAndOwner = =>
        delete o.recursive
        @chown path, o, =>
          @chmod path, o, next
      @test "test -d #{path}", code: 1, (necessary) =>
        return @skip "directory already exists.", setModeAndOwner unless necessary
        @execute "mkdir"+
          "#{if o?.recursive then ' -p' else ''}"+
          " #{path}", o, setModeAndOwner

  # download a file from the internet to the remote host with wget
  download: (uris, [o]..., cb) =>
    @die "to is required." unless o?.to
    @each @getNames(uris), cb, (uri, nextFile) =>
      ((download)=>
        unless o?.replace # TODO: use checksum to assume replacement necessary
          @test "test -f #{uri}", code: 1, (necessary) =>
            download() if necessary
      )(=>
        @execute "wget -nv #{uri}#{if o?.to then " -O #{o.to}" else ""}", o, =>
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
    @execute "rm -f #{o.to}", sudo: true, =>
      @ssh.put paths, o.to, (err) =>
        @die "error during SFTP file transfer: #{err}" if err
        @log "SFTP upload complete."
        @chown o.to, o, =>
          @chmod o.to, o, =>
            @execute "mv #{o.to} #{o.final_to}", sudo: true, cb

  template: (paths, [o]..., cb) =>
    paths = path.join.apply null, @getNames paths
    @die "to is required." unless o?.to
    # use attrs from @server namespace
    variables = server: @server, networks: @networks
    if o?.variables
      # variables will only apply if not provided anywhere else
      variables = _.merge o.variables, variables
      o.variables = null
    # read template
    fs.readFile "#{paths}.coffee", encoding: 'utf-8', (err, template) =>
      @die err if err
      # render template from variables
      output = TemplateRenderer.render.apply variables, [template]
      console.log "---- BEGIN TEMPLATE ----\n#{output}\n--- END TEMPLATE ---"
      @strToFile output, o, cb

   strToFile: (str, [o]..., cb) =>
      ver = crypto.createHash('sha1').update(str).digest('hex')
      @log "rendered file #{o.to} version #{ver}"
      # write string to file on local disk
      tmpFile = path.join '/tmp/', ver # NOTICE: for windows compatibility this could go into __dirname locally
      o.final_to = o.to; o.to = '/tmp/'+ver
      fs.writeFile tmpFile, str, (err) =>
        @die err if err
        # upload file
        @upload tmpFile, o, =>
          # delete file
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

  user: (name, [o]..., cb) =>
    # TODO: check for success. test if necessary
    @execute "useradd #{name}", sudo: true, cb

  group: (name, [o]..., cb) =>
    # TODO: check for success. test if necessary
    @execute "groupadd #{name}", sudo: true, cb

  link: (src, [o]..., cb) =>
    @die "target is required." unless o?.target
    @test "test -L #{o.target}", code: 1, (necessary) =>
      if necessary
        @execute "ln -s #{src} #{o.target}", o, @mustExit 0, cb
      else
        @execute "rm #{o.target}", o, =>
          @execute "ln -s #{src} #{o.target}", o, @mustExit 0, cb

  deploy: (name, [o]..., cb) =>
    # TODO: support shared dir, cached-copy, and symlinking logs and other stuff
    # TODO: support keep_releases
    o.sudo = o.owner
    privateKeyPath = "/home/#{o.owner}/.ssh/id_rsa" # TODO: make this a safer name; to avoid overwriting existing file
    @directory "/home/#{o.owner}/", owner: o.owner, group: o.group, sudo: true, recursive: true, mode: '0700', =>
      @directory "/home/#{o.owner}/.ssh/", owner: o.owner, group: o.group, sudo: true, recursive: true, mode: '0700', =>
        # write ssh key to ~/.ssh/
        @strToFile o.git.deployKey, owner: o.owner, group: o.group, sudo: true, to: privateKeyPath, mode: '0600', =>
          # create the release dir
          @execute 'echo -e "Host github.com\\n\\tStrictHostKeyChecking no\\n" | '+"sudo -u #{o.sudo} tee -a /home/#{o.owner}/.ssh/config", => # TODO: find a better alternative
            @test "git ls-remote #{o.git.repo} #{o.git.branch}", o, rx: `/[a-f0-9]{40}/`, (matches) =>
              remoteRef = matches[0]
              release_dir = "#{o.deploy_to}/releases/#{remoteRef}"
              @directory release_dir, owner: o.owner, group: o.group, sudo: true, recursive: true, =>
                @execute "git clone -b #{o.git.branch} #{o.git.repo} #{release_dir}", sudo: o.sudo, =>
                  @link release_dir, target: "#{o.deploy_to}/current", sudo: o.sudo, cb

                #@ssh.cmd "svn info --username #{o.svn_username} --password #{o.svn_password} --revision #{o.revision} #{o.svn_arguments} #{o.repository}", (data: (data, type) ->
                #  out += data.toString() if type isnt 'stderr'
                #), (code, signal) =>
                #  @die 'svn info failed' unless code is 0
                #  @die 'svn revision not found' unless current_revision = ((m = out.match /^Revision: (\d+)$/m) && m[1])
                #  release_dir = path.join releases_dir, current_revision
                #  @ssh.cmd "sudo mkdir -p #{release_dir}", {}, =>
                #    @ssh.cmd "sudo chown -R #{o.owner}.#{o.group} #{release_dir}", {}, =>
                #      @ssh.cmd "sudo -u#{o.owner} svn checkout --username #{o.svn_username} --password #{o.svn_password} #{o.repository} --revision #{current_revision} #{o.svn_arguments} #{release_dir}", {}, ->
                #        current_dir = path.join o.deploy_to, 'current'
                #        link release_dir, current_dir, cb

  setEnv: (k, [o]..., cb) =>
    @die "value is required." unless o?.value?
    # remove any lines referring to the same key; this prevents duplicates
    file = "/etc/environment"
    @execute "sed -i '/^#{k}=/d' #{file}", sudo: true, =>
      # append key and value
      @execute "echo '#{k}=#{o.value}' | sudo tee -a #{file} >/dev/null", @mustExit 0, cb #=>
        ## set in current env
        #@execute "export #{k}=\"#{o.value}\"", cb

  #cron: (name, [o]..., cb) ->
  #  cb()
