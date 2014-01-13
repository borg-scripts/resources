async = require 'async2'
delay = (s, f) -> setTimeout f, s

global.execute = (line, [o]..., cb) ->
  o ||= {}
  go = ->
    ssh.cmd line, {}, cb
  return go() unless o.not_if
  execute o.not_if, (code) ->
    return cb() if code is 0
    go()

did_apt_get_update_this_session = false
global.install = (pkgs, [o]..., cb) ->
  # TODO: unless dpkg --list | grep build-essential
  # TODO: save some metadata on the remote host recording last update date and dont run until its been 24hrs?
  o ||= {}
  flow = new async
  pkgs = pkgs.split(/[\r\n\s]+/)
  unless did_apt_get_update_this_session
    flow.serial ->
      execute "sudo apt-get update", @
      did_apt_get_update_this_session = true
  flow.serial ->
    execute "sudo apt-get install -y #{pkgs.join ' '}", @
  return flow.go cb unless o.not_if
  execute o.not_if, (code) ->
    return cb() if code is 0
    flow.go cb

uninstall = ->
service = ->

# private helper
chown = (o, cb) ->
  return cb() unless o?.user or o.group
  execute "sudo chown "+
    "#{if o.recursive then '-R ' else ''}"+
    "#{if o.user then "#{o.user}" else ''}"+
    "#{if o.group then ".#{o.group}" else ''}"+
    " #{o.path}", cb

chmod = (o, cb) ->
  return cb() unless o?.mode
  execute "sudo chmod "+
    "#{if o.recursive then '-R ' else ''}"+
    "#{o.mode} #{o.path}", cb

global.directory = (path, [o]..., cb) ->
  o ||=  {}
  execute "sudo mkdir"+
    "#{if o.recursive is false then '' else ' -p'}"+
    "#{if o.mode then " -m#{o.mode}" else ''}"+
    " #{path}", ->
      o.path = path
      chown o, cb

global.remote_file = (localfile, [o]..., cb) ->
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

global.dpkg_package = (pkg, [o]..., cb) ->
  throw "source is required" unless o?.source
  go = -> execute "sudo dpkg -i #{o.source}", cb
  return go() unless o.not_if
  execute o.not_if, (code) ->
    return cb() if code is 0
    go()

global.put_file = (file, [o]..., cb) ->
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

global.log = (msg, [o]..., cb) ->
  Logger.out type: 'info', msg
  cb()

global.reboot = ([o]..., cb) ->
  go = ->
    log '''
    ###############################
    ###############################
    #####  REBOOTING SERVER #######
    ###############################
    ###############################
    ''', ->
      execute "sudo reboot", ->
        log "waiting for server to reboot...", ->
          delay o.wait or 60*1000, ->
            log "re-establishing ssh connection", ->
              ssh.connect ->
                cb()
  # TODO: make a generic private method that performs not_if and only_if checks for every resource
  return go() unless o.not_if
  execute o.not_if, (code) ->
    return cb() if code is 0
    go()
