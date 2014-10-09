#Guard Functions
These are short-hand conditional wrappers which help you determine whether a step has already been performed so you can skip it on subsequent runs.

##test
Executes a command and verifies that the expected exit code is returned from the shell. This is generally used to verify that a command has executed successfully. Most successful commands return an exit code of 0.

###Usage
```@test "stat /usr/bin/apt", code: 0, (res) =>
      return @skip "We don't know how to add a package source on non-Debian systems." if res```

#Utility Functions
These functions comprise the bulk of each Borg script.

##execute
Executes a command on the shell.

Though this allows maximal flexibility, it should be used sparingly because it defeats potential OS agnositicism. It is better to use functions that semantically describe the task to be accomplished and allow OS-specific implementations to be invoked behind the scenes.

###Parameters
```cmd```: the command to execute on the target system shell
* *(optional)* ```sudo```: If true, command is wrapped in sudo. Defaults to false.

###Usage
```
@execute “ls /root”,
  sudo: true
```

##package_update
Update the metadata of the OS’s native package manager.

This is usually used to sync metadata like available packages and package versions with the mirrors.

###Parameters
None.

###Usage
```
@package_update
```

##install
Removes package(s) using the OS’s native package manager.

###Parameters
* ```pkgs```: a space-delimited string of package names to install

###Usage
```
@install “apache2 php5”
```

##uninstall
Removes package(s) using the OS’s native package manager.

###Parameters
* ```pkgs```: a space-delimited string of package names to install

###Usage
```
@uninstall “apache2 php5”
```

##service
Invoke the “service” system command (typically in /usr/sbin/service) to manage services and daemons.

###Parameters
* ```svc_names```: a space-delimited list of services to control
* *(optional)* ```action```: the command to send to the services. Usually one of start, restart, or stop. If omitted, defaults to start.

###Usage
```
@service “apache2”,
  action: “restart”
```

##chown
Updates file ownership.

###Parameters
* ```paths```: a space-delimited list of paths to set
* *(optional)* ```owner```: the system user to receive ownership. Required if group is absent.
* *(optional)* ```group```: the system group to receive groupship. Required is owner is absent.
* *(optional)* ```recursive```: If true, the ownership will be applied recursively to all children of the listed paths.

###Usage
```
@chown “/tmp/test”,
  owner: “jeffcook”
  group: “jeffcook”
  recursive: true
```

##chmod
Updates file permission bits.

###Parameters
* ```paths```: a space-delimited list of paths to set
* ```mode```: the octal representation of permission bits to set.
* *(optional)* ```recursive```: If true, the permission bits will be applied recursively to all children of the listed paths.

###Usage
```
@chmod “/tmp/test”,
  mode: 0644
  recursive: true
```
