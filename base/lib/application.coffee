# extends Date
require "date-utils"

_            = require "lodash"
log4js       = require "log4js"
express      = require "express"
walkTreeSync = require "./walktree"
fs           = require "fs"
redis        = require "redis"

{ Js2Xml }                    = require "js2xml"
{ RedisError, NotFoundError } = require "./error"

class exports.Application
  @env = ( process.env.NODE_ENV or "development" )

  constructor: ( @binding_host, @port ) ->
    app = express()

    @_configure app

  redisConnect: ( cb ) =>
    # grab the redis config
    { port, host } = @config.redis

    @redisClient = redis.createClient( port, host )

    @redisClient.on "error", ( err ) ->
      throw new RedisError err

    @redisClient.on "ready", cb

  script: ( cb ) ->
    @configureModels()

    @redisConnect ( err ) =>
      throw err if err
      cb ( ) => @redisClient.quit()

  run: ( callback ) ->
    @express = @app.listen @port, @binding_host
    callback()

  configureMiddleware: ( ) ->
    return @

  configureControllers: ( ) ->
    @controllers = {}

    return @ unless @constructor.controllersPath

    for [ abs, clean_path ] in @_controllerList()
      try
        classes = require abs

        for cls, func of classes
          ctrlr =  new func @, clean_path

          # this is used by the documentation generator
          @controllers[ cls ] = ctrlr

          @logger.debug "Loading controller #{ cls } with path '#{ ctrlr.path() }'"
      catch e
        throw new Error( "Failed to load controller #{abs}: #{e}" )

    return @

  configureModels: ( ) ->
    @models or= {}

    modelPaths = @_modelList( "#{ __dirname }/../app/model" )

    # add the new models
    if @constructor.modelsPath
      modelPaths = modelPaths.concat( @_modelList( @constructor.modelsPath ) )

    for modelPath in modelPaths
      current = require( modelPath )

      for model, func of current
        # lowercase the first char of the model name
        modelName = model.charAt( 0 ).toLowerCase() + model.slice( 1 )

        if func.instantiateOnStartup
          @logger.debug "Loading model '#{model}'"

          # models take an instance of this class as an argument to the
          # constructor. This gives us something like
          # `application.models.metaCache`.
          @models[ modelName ] = new func @

    return this

  model: ( name ) ->
    @models[ name ] or null

  controller: ( name ) ->
    @controllers[ name ] or null

  _modelList: ( initialPath ) ->
    list = []

    walkTreeSync initialPath, null, ( path, filename, stats ) ->
      return unless matches = /(.+?)\.(coffee|js)$/.exec filename

      list.push "#{ path }/#{ matches[1] }"

    return list

  # grab the list of controllers (which can just be required)
  _controllerList: ( ) ->
    list = []

    walkTreeSync @constructor.controllersPath, null, ( path, filename, stats ) ->
      return unless matches = /(.+?_controller)\.(coffee|js)$/.exec filename

      abs = "#{ path }/#{ matches[1] }"

      # strip the controllers part from the path and pass it in so
      # modules can derive thier views/controller paths.
      clean_path = abs.replace( "./app/controller/", "" )
                      .replace( /_controller/, "" )

      list.push [ abs, clean_path ]

    return list

  _configure: ( app ) ->
    default_config =
      redis:
        host: "localhost"
        port: 6379
      logging:
        level: "INFO"
        appenders: [
          {
            type: "file",
            filename: "#{ Application.env }-#{ @port }.log"
          }
        ]

    # load up /our/ configuration (from the files in /config)
    [ config_filename, @config ] = require( "./app_config" )( Application.env )
    @config = _.merge default_config, @config

    app.configure ( ) =>
      @configureGeneral app
      @configureLogging app

      if config_filename
        @logger.info "Loading configuration from '#{ config_filename }'."

      # now let the rest of the class know about app
      @app = app

  configureGeneral: ( app ) ->
    app.use app.router

    # offload any errors to onError
    app.use ( err, req, res, cb ) =>
      @onError err, req, res, cb

  configureLogging: ( app ) ->
    logging_config = @config.logging
    log4js.configure logging_config

    @debug = true if logging_config.level is "DEBUG"

    @logger = log4js.getLogger()
    @logger.setLevel logging_config.level

  onError: ( err, req, res, next ) ->
    output =
      error:
        type: err.name
        message: err.message

    output.error.details = err.details if err.details

    # add the stacktrace if we're debugging
    if @debug
      output.error.stack = err.stack

    status = err.constructor.status or 400

    # json
    if req.api?.data.apiFormat isnt "xml"
      meta =
        version: 1
        status_code: status

      return res.json status,
        meta: meta
        results: output

    # need xml
    res.contentType "application/xml"
    js2xml = new Js2Xml "error", output.error
    return res.send status, js2xml.toString()
