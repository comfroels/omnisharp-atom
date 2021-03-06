fs = require('fs')
spawn = require('child_process').spawn
BrowserWindow = require('remote').require('browser-window')
OmnisharpLocation = require('omnisharp-server-binaries')
findFreePort = require('freeport')

module.exports =
  class OmniSharpServer
    instance = null

    # MVVM relies on evaling expressions that we are not allowed to do
    # in the sandboxed atom editor so all states needs to be truethy
    # there is a loophole package to enable Function/parse/eval but
    # I did not get it to work

    @vm:
      isNotLoading: true
      isLoading: false
      isOff: true
      isNotOff: false
      isOn: false
      isNotReady: true
      isReady: false
      isNotError: true
      isError: false

      isLoadingOrReady: false

      state: "off"
      previousState: "off"

    atom.on "omni-sharp-server:state-change", (state) =>
      @vm.previousState = @vm.state
      @vm.state = state

      @vm.isOn = state == "on"
      @vm.isOff = state == "off"
      @vm.isNotOff = state != "off"

      #if we recieve off after error prefer to stay in error mode
      @vm.isError = state == "error" || (state == "off" && @vm.previousState == "error")
      @vm.isNotError = !@vm.isError
      @vm.isOffOrError = @vm.isError || @vm.isOff
      @vm.isOffAndNotError = !@vm.isError && @vm.isOff

      @vm.isLoading = state == "loading"
      @vm.isNotLoading = state != "loading"

      @vm.isReady = state == "ready"
      @vm.isNotReady = !@vm.isReady

      @vm.isLoadingOrReady = state == "ready" || state == "loading"
      @vm.isLoadingOrReadyOrError = @vm.isLoadingOrReady || @vm.isError


      @vm.iconText = if @vm.isError then "omni error occured" else ""

      atom.emit "omni-sharp-server:state-change-complete", state


    class OmniSharpServerInstance
      packageDir = atom.packages.packageDirPaths[0];
      #location = "#{packageDir}/omnisharp-atom/server/OmniSharp/bin/Debug/OmniSharp.exe"
      location = OmnisharpLocation

      start: () ->
        useMono = process.platform isnt "win32"
        executablePath = if useMono then "mono" else location

        findFreePort (err, port) =>
          if err
            return console.error "error finding freeport: ", err

          @port = port
          serverArguments = [ "-s", atom?.project?.getPaths()[0], "-p", port]

          if useMono
            serverArguments.unshift location

          @child = spawn(executablePath, serverArguments)
          atom.emit "omni-sharp-server:start", @child.pid, port
          atom.emit "omni-sharp-server:state-change", "loading"
          @child.stdout.on 'data', @out
          @child.stderr.on 'data', @err
          @child.on 'close', @close
          @child.on 'error', @err

      out: (data) =>
        s = data.toString()
        if s.match(/Solution has finished loading/)?.length > 0
          atom.emit "omni-sharp-server:ready", @child.pid
          atom.emit "omni-sharp-server:state-change", "ready"

        if s.match(/Detected an OmniSharp instance already running on port/)?.length > 0
          atom.emit "omni-sharp-server:error"
          atom.emit "omni-sharp-server:state-change", "error"
          @stop()

        atom.emit "omni-sharp-server:out", s

      err: (data) =>
        friendlyMessage = @parseError(data)
        atom.emit "omni-sharp-server:err", friendlyMessage

      close: (data) =>
        atom.emit "omni-sharp-server:close", data
        atom.emit "omni-sharp-server:state-change", "off"
        @port = null

      stop: () ->
        @child?.kill "SIGKILL"
        @child = null

      toggle: () -> if @child then @stop() else @start()

      parseError: (data) ->
        message = data.toString()
        if data.code == 'ENOENT' and data.path == 'mono'
          message = 'mono could not be found, please ensure it is installed and in your path'
        message

    @get: () ->
      instance ?= new OmniSharpServerInstance()
