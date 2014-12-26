_ = require 'lodash'
fs = require 'fs'
path = require 'path'
async = require 'async2'
crypto = require 'crypto'
TemplateRenderer = require './template_renderer'
delay = (s, f) -> setTimeout f, s
bash_esc = (s) -> (''+s).replace `/([^0-9a-z-])/gi`, '\\$1'

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
      data: (data) => out += data
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
    else # empty
      done_cb() # carry on

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
        sudo = 'sudo '
        sudo += "-u#{o.sudo} " if o.sudo isnt 'root'
      cmd = "#{if o?.cwd then "cd #{o.cwd} && " else ""}#{sudo}#{cmd}"
    else if o?.su
      cmd = if o?.cwd then "cd #{o.cwd} && #{cmd}" else cmd
      cmd = "sudo su - #{if typeof o.su is 'string' and o.su isnt 'root' then o.su+' ' else ''}-c #{bash_esc cmd}"
    unless o?.retry?
      return @ssh.cmd cmd, o, ->
        if o?.ignore_errors
          cb()
        else
          cb.apply null, arguments

    tries = o.retry
    try_again = => @ssh.cmd cmd, o, (code) =>
      if code is 0 then cb code
      else
        if --tries > 0 then try_again()
        else cb code
    try_again()

  package_update: (cb) =>
    # TODO: save .dotfile on remote host remembering last update date between sessions,
    #       and then check it and only run when its not there or has been >24hrs
    @execute 'apt-get update', sudo: true, retry: 3, @mustExit 0, =>
      # also update packages to latest releases
      @execute 'DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y', sudo: true, retry: 3, @mustExit 0, cb

  install: (pkgs, [o]..., cb) =>
    @test "dpkg -s #{@getNames(pkgs).join ' '} 2>&1 | grep 'is not installed and'", code: 0, (necessary) =>
      return @skip "package(s) already installed.", cb unless necessary
      @execute "DEBIAN_FRONTEND=noninteractive apt-get install -y "+
        "#{@getNames(pkgs).join ' '}", sudo: true, retry: 3, @mustExit 0, cb

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
    o ||= {}; o.mode ||= '0755'
    recursive = o.recursive
    @each @getNames(paths), cb, (path, next) =>
      setModeAndOwner = =>
        delete o.recursive
        @chown [path], o, =>
          @chmod [path], o, next
      @test "test -d #{path}", code: 1, (necessary) =>
        return @skip "directory already exists.", setModeAndOwner unless necessary
        @execute "mkdir"+
          "#{if recursive then ' -p' else ''}"+
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
          @chown o.to, o, =>
            @chmod o.to, o, =>
              return nextFile() unless o?.checksum
              @test "sha256sum #{o.to}", rx: /[a-f0-9]{64}/, (hash) =>
                @die "download failed; expected checksum #{JSON.stringify o.checksum} but found #{JSON.stringify hash[0]}." unless hash[0] is o.checksum
                nextFile()
      )


  test_v2: (cmd, [o]..., test_cb, success_cb, fail_cb) =>
    @execute cmd, o, (code) =>
      #cb if test_cb.apply code: code then null else die_msg
      if test_cb.apply(code: code)
        success_cb()
      else
        fail_cb()

  # upload a file from localhost to the remote host with sftp
  upload: (paths, [o]..., cb) =>
    paths = path.join.apply null, paths if Array.isArray paths
    @die "to is required." unless o?.to
    o.force = true if typeof(o.force) == undefined
    #TODO: not if path with same sha256sum already exists
    #TODO: this will be broken out soon and can be removed
    @test_v2 "stat #{o.to}", sudo: o?.sudo, (-> @code is 0 and o.force is false), =>
      @die "You're trying to overwrite a file that already exists: #{o.to}. Please specify force: true if you're sure you want to do this."
    , =>
      fs.readFile "#{paths}", encoding: 'utf-8', (err) =>
        @die err if err
      @execute "rm -f #{o.to}", sudo: true, =>
        unless o?.final_to
          final_to = o.to
          to = "/tmp/#{Math.random().toString(36).substring(2,8)}"
        else
          final_to = o.final_to
          to = o.to

        @log "SFTP uploading #{fs.statSync(paths).size} bytes from #{JSON.stringify paths} to #{JSON.stringify to}..."
        @ssh.put paths, to, (err) =>
          @die "error during SFTP file transfer: #{err}" if err
          @log "SFTP upload complete."
          @chown to, o, =>
            @chmod to, o, =>
              @execute "mv #{to} #{final_to}", sudo: true, cb

  template: (paths, [o]..., cb) =>
    a = =>
      if o?.hasOwnProperty 'content'
        o.to = paths
        b null, o.content
      else
        # read template from disk
        paths = path.join.apply null, @getNames paths
        fs.readFile "#{paths}.coffee", encoding: 'utf-8', b
    b = (err, template) =>
      @die "to is required." unless o?.to
      @die err if err
      # compile template variables
      # from @server attributes
      variables = server: @server, networks: @networks
      # and provided variables key
      if o?.variables
        variables = _.merge o.variables, variables
        o.variables = null # prevent template from accidentally modifying provided object

      # render template from variables
      output = TemplateRenderer.render.apply variables, [template]
      @strToFile output, o, cb
    a b

   strToFile: (str, [o]..., cb) =>
      ver = crypto.createHash('sha1').update(str).digest('hex')+Math.random().toString(36).substring(2,8)
      @log "rendered file #{o.to} version #{ver}"
      console.log "---- BEGIN FILE ----\n#{str}\n--- END FILE ---"
      # write string to file on local disk
      # NOTICE: for windows compatibility this could go into __dirname locally
      tmpFile = path.join '/tmp/', 'local-'+ver
      o.final_to = o.to; o.to = '/tmp/remote-'+ver
      fs.writeFile tmpFile, str, (err) =>
        @die err if err
        # upload file
        @upload tmpFile, o, =>
          # delete file
          fs.unlink tmpFile, (err) =>
            #@die err if err # for some reason, it does fail to cleanup locally sometimes--but we don't care enough to die
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

  group: (name, [o]..., cb) =>
    @execute "groupadd #{name}", o, (code) =>
      # NOTICE: can't pass cb directly as any code other than 0 would
      #         be considered an error to the flow control next(err),
      #         and here we don't care if there is an error.
      cb()

  link: (src, [o]..., cb) =>
    @die "target is required." unless o?.target
    @test "test -L #{o.target}", code: 1, (necessary) =>
      if necessary
        @execute "ln -s #{src} #{o.target}", o, @mustExit 0, cb
      else
        @execute "rm #{o.target}", o, =>
          @execute "ln -s #{src} #{o.target}", o, @mustExit 0, cb

  # need a better name for this.
  # kind of want to make it part of @execute with some option passed or refactor to make it the norm
  get_remote_str: (cmd, cb) => out = ''; @execute cmd, ( data: (str) => out += str ), (code) => cb code, out.trim()

  deploy: (name, [o]..., cb) =>
    # TODO: support shared dir, cached-copy, and symlinking logs and other stuff
    # TODO: support keep_releases
    o.sudo = o.owner
    o.keep_releases ||= 3
    privateKeyPath = "$(echo ~#{o.owner})/.ssh/id_rsa" # TODO: make this a safer name; to avoid overwriting existing file
    @directory ["$(echo ~#{o.owner})/"], owner: o.owner, group: o.group, sudo: true, recursive: true, mode: '0700', =>
      @directory ["$(echo ~#{o.owner})/.ssh/"], owner: o.owner, group: o.group, sudo: true, recursive: true, mode: '0700', =>
        # write ssh key to ~/.ssh/
        @strToFile o.git.deployKey, owner: o.owner, group: o.group, sudo: true, to: privateKeyPath, mode: '0600', =>
          # create the release dir
          @execute 'echo -e "Host github.com\\n\\tStrictHostKeyChecking no\\n" | '+"sudo -u #{o.sudo} tee -a $(echo ~#{o.owner})/.ssh/config", => # TODO: find a better alternative
            @test "git ls-remote #{o.git.repo} #{o.git.branch}", o, rx: `/[a-f0-9]{40}/`, (matches) =>
              @die "can't reach github" unless Array.isArray matches
              remoteRef = matches[0]
              @directory o.deploy_to, owner: o.owner, group: o.group, sudo: true, recursive: true, =>
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

  addPackageSource: (k, [o]..., cb) =>
    @die "Mirror is required." unless o?.mirror?
    @die "Channel is required." unless o?.channel?
    @die "Repository name is required." unless o?.repo?

    @test_v2 "stat /usr/bin/apt", (-> @code is 0)
    , =>
      @execute "echo \"deb #{o.mirror} #{o.channel} #{o.repo}\" | sudo tee -a /etc/apt/sources.list", sudo: true, cb
    , =>
      @skip "we don't know how to add a package source on non-Debian systems", cb

  file_append_line: (file_path, matching_string, replacement_line, cb) =>
    # TODO: should make this optionally take o.sudo, o.mode, etc.
    @test_v2 "grep #{bash_esc matching_string} #{bash_esc file_path}", (-> @code is 0)
    , =>
      @log "Matching line found, not appending"
      cb()
    , =>
      @log "Matching line not found, appending..."
      @execute "echo #{bash_esc replacement_line} | sudo tee -a #{bash_esc file_path}", (code) =>
        @die "FATAL ERROR: unable to append line." unless code is 0
      cb()

  file_replace_line: (file_path, matching_string, replacement_line, cb) =>
    @test_v2 "grep #{bash_esc matching_string} #{bash_esc file_path}", (-> @code isnt 0)
    , =>
      @log "Matching line found, replacing..."
      @execute "sed -i.bak #{bash_esc file_path} s/#{bash_esc matching_string}/#{bash_esc replacement_line}/g", sudo: true, (code) =>
        @die "FATAL ERROR: unable to replace line." unless code is 0
        cb()
    , =>
      @log "Matching line not found, not replacing"
      cb()
  # TODO: maybe put this in a vendor/cron repo
  #cron: (name, [o]..., cb) ->
